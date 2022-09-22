# Demo app for Watchdog

*TL;DR: Watchdog lets you always have a single instance of your GenServer in your cluster, which will preserve its state and continue using it without interruption as it's automatically moved around the cluster during node shutdowns/deployments/etc.*

Imagine you have an Elixir app. Let's say you have a GenServer or a few that are meant to be "singletons" in your cluster - you never want to have more than one running.

This is generally a pattern you want to avoid if you can, but sometimes it can be difficult to escape without significant effort or external tools (locks, rate limiting, certain types of metadata, etc). And I'd like to stay within Elixir if possible.

**Watchdog** is a proof-of-concept simple library that makes this sort of pattern significantly easier to use than existing solutions, relying on top of OTP's amazing principles.

Here's an example:

```elixir
defmodule TestServer do
  use Watchdog.SingletonGenServer
  require Logger

  def initial_state do
    %{}
  end

  def setup(state, _meta) do
    Logger.info("started test server with state #{inspect(state)}")

    {:ok, state}
  end

  def handle_call({:some_command}, _from, state) do
    # do something
    {:reply, :ok, state}
  end

  def import_state(initial_state, imported_state) do
    Map.merge(initial_state, imported_state)
  end
end
```

Now just add:

```elixir
children = [
  {Watchdog, processes: [TestServer]}
]
```

to your supervisor and you're good to go. This is a GenServer, but with special powers.

* There will never be more than one in the cluster, no matter how many nodes you start.
* There will never be less than one in a cluster, even if a node crashes or goes down. Watchdog reacts *basically immediately*, so a replacement process will be started in an instant.
* If two nodes join a cluster simultaneously and both are already running a SingletonGenServer, we'll gracefully **merge the state and process mailbox (any not-yet-processed calls)** from the older SingletonGenServers into the newer SingletonGenServer and shut down the older process.
* If a node is shutting down (e.g. by SIGTERM), and a SingletonGenServer is running on it, the SingletonGenServer will gracefully **hand off its state and process mailbox** to a brand new SingletonGenServer on another node, which will pick right up where it left off. 

The implications of this are pretty cool. 

My favorite is what this means for the typical scenario of rolling deployments, like on Heroku/Render/Fly.io/etc. You have a GenServer that's processing tons of requests, and you need to deploy a new version, so you spin up a new deployment and need to shut down the old one.

Traditionally, this results in lost data - if you're keeping state in a GenServer, when the new process in the new deployment is started and old one is eventually killed, anything that was held in the state of the original is lost, including any `GenServer.call` requests that were sent after the SIGTERM, which will all error out with timeouts.

You could wire a handoff yourself, but this can be tricky to do with process registration/unregistration timing, trapping exits, and so on.

Watchdog makes this dead-simple. Just define an `import_state/2` function in your `SingletonGenServer`:

```elixir
def import_state(initial_state, imported_state) do
  Map.merge(initial_state, imported_state)
end
```

If this function is called, that means your process is the new singleton and is taking over the state of the old singleton process. In this function, do whatever processing you need to do to the state to get it ready for the new GenServer, then return the new state. That's it - you're good to go.

How about in-flight messages/`call`s/`cast`s that were on the way? You don't have to do anything special at all, Watchdog handles those automatically. If your GenServer was being slammed with calls and some came in after the SIGTERM was sent, no worries - all those not-yet-processed calls will be transferred to the replacement singleton process which will pick right up where this one left off.

**This means that any `GenServer.call`s that were being sent to the singleton process continue to seamlessly work before, during, and after the new singleton process takes over.** Isn't that cool?

## How do I use this?

This is a proof-of-concept, not a published library (yet). Please feel free to take any code from this repo under MIT, but no warranties or support provided.

To use Watchdog, you just need `watchdog.ex` and the `watchdog` directory in `lib` from this repo, put into your app. Then add:

```
{Watchdog, processes: [TestServer, AnotherServer]},
```

to the children of your main supervisor. To write your GenServer, you just need the following:

Replace `use GenServer` with `use Watchdog.SingletonGenServer`. 

Don't define a start_link, init, or terminate callback - Watchdog handles those for you. Instead, define a `setup/2` function that does anything you would've needed to do in `init`. 

`setup/2` has the following signature:

```elixir
def setup(state, %{was_imported: true}) do
  # was_imported is either true or false and lets you know whether state was imported into this GenServer on startup

  # the return value of this function is the same as you would return in init.
  {:ok, state}
end
```

You'll also need to define:

```elixir
def initial_state do
  %{}
end
```

as you might expect, this is the initial state of the GenServer.

Finally, define: 

```elixir
def import_state(initial_state, imported_state) do
  # do whatever you need to do here to import the state
  # return the resulting final state

  # for example,
  # Map.merge(initial_state, imported_state)

  # this might be called when the GenServer is first starting up 
  # (if it's taking over from another singleton)

  # or it might be called when it's already running (during conflict
  # resolution), if this GenServer is chosen as the "winning" one and needs
  # to merge in state from the "losing" GenServers
end
```

That's it - you have a magic GenServer which will move around your cluster as needed when the node it's running on is shutting down (or during netsplit resolution).

## How does this work?

#### Per-node cluster aware supervisors

OTP provides a great abstraction to ensure a single process runs in the cluster, by way of the `{:global, :atom}` tuple. But on its own, it's not quite enough for a robust solution.

It guarantees that only one process will be *registered* in a cluster, but it doesn't make sure that one process always *exists* in a cluster. We need supervisors for that.

So Watchdog provides a cluster-aware supervisor which will always attempt to start a process as long as there isn't one currently running in the cluster. If it finds out that another supervisor has already beat our node to it, it will simply monitor that already-started process and react as soon as it goes down.

#### Conflict resolution

If two Elixir nodes are started separately and join each other later (or in the case of a netsplit), you may end up with two instances of a singleton which suddenly discover each other when the cluster is formed. So we need to resolve the conflict - only one process can be in the cluster, so which one stays?

`{:global, _}`'s default conflict resolution brutal_kills a process at random. Watchdog tracks node age and shuts down the oldest process, as that's more likely the one that will not be sticking around in case of a rolling deployment.

Additionally, instead of a brutal kill, we send a special message which allows the outgoing GenServer to gracefully hand off its state to the "winner" GenServer.

#### GenServer state handoff

If the node is shutting down (SIGTERM or otherwise), we trap exits and hand off GenServer state to another node right before shutting down the GenServer. We pick the newest node in the cluster, as that's the more likely the one that was most recently deployed and will stick around longer than an older node.

Same logic happens if we're doing a conflict resolution kill instead of a node-shutting-down kill.

#### GenServer process mailbox handoff

There might be some messages that haven't been handled yet in the mailbox as we're shutting down. In the interest of not losing them, they're pulled from the mailbox and sent to the replacement GenServer process via `send`, to reintroduce them back into the new process's mailbox as if nothing ever happened.

## Other solutions

This can be combined perfectly with `libcluster` and a cloud like Fly/Render/etc to make sure your singletons automatically stay running during deployment handoffs. Just configure `libcluster` and set Watchdog up as in the instructions above, and you're all set.

As far as I'm aware, none of the other clustering solutions (horde, swarm, syn) support this type of state/mailbox handoff. I've tested just about all of them and found `{:global, Module}` to be the most reliable as a process registry in production, and tend to prefer it to any alternatives, so it makes up the base of Watchdog. 
