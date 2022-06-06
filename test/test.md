## Manual fixes required

Async wakes up multiple times a second even if nothing is happening in order to work around deadlocks.
This can mask bugs while testing, so you should edit the async code manually to disable that:

- Set `max_inter_cycle_timeout` to some very long value (e.g. 10 minutes).
- Disable `detect_stuck_thread_pool`, or make that use a long interval too.

## Setup

Some imports:

```ocaml
# #require "async_kernel";;
# #require "async_unix";;
# #require "core";;
# #require "eio_main";;
# #require "async_eio";;
# #require "threads.posix";;
# open Eio.Std;;
```

## Check for races

In Async, blocking operations run in separate systreads from a pool, like in Lwt.
In Lwt, when a job is complete it signals the main thread, which picks up the result and continues.
But in Async, the worker thread can take the async mutex and start running the main OCaml code directly.
The Lwt system works very easily with Eio because the job threads are just an implementation detail.
But with Async we need to avoid running Eio fibers in the main thread at the same time as Async is running OCaml code in the workers.

For example, imagine we have some resource that must only be accessed by one thread at a time
(we'll make it `Atomic` here just to help detect problems). Each user sets it to one, does a domain-blocking sleep,
and then sets it back to zero:

```ocaml
let resource = Atomic.make 0

let use_resource () =
  if not (Atomic.compare_and_set resource 0 1) then failwith "Race detected!";
  Unix.sleepf 0.1;
  if not (Atomic.compare_and_set resource 1 0) then failwith "Race detected!"
```

```ocaml
# Eio_main.run @@ fun _env ->
  Async_eio.with_event_loop @@ fun _ ->
  let async_ready, set_async_ready = Promise.create () in
  Fiber.both
    (fun () ->
       Promise.await async_ready;
       (* Async has created a new thread, which took the async lock.
          This code must not run until it releases the lock. *)
       traceln "Eio code running";
       use_resource ();
       traceln "Eio code done"
    )
    (fun () ->
       Async_eio.run_async (fun () ->
          let open Async_kernel in
          let open Async_unix in
          In_thread.(run ~when_finished:When_finished.Take_the_async_lock) ignore >>= fun () ->
          (* We wake up the Eio thread here, but it can't run yet as we have the async lock. *)
          Promise.resolve set_async_ready ();
          Format.eprintf "+Async code running@.";
          use_resource ();
          Format.eprintf "+Async code done@.";
          return ()
       )
    );;
+Async code running
+Async code done
+Eio code running
+Eio code done
- : unit = ()
```

## Check for deadlock

However, Eio must release the async lock when waiting for IO. Otherwise, Async tasks can't make progress:

```ocaml
# Eio_main.run @@ fun _env ->
  let r, w = Unix.pipe () in
  Async_eio.with_event_loop @@ fun _ ->
  Fiber.both
    (fun () ->
       traceln "Eio blocking...";
       Eio_unix.await_readable r;
       traceln "Eio ready to read";
       Unix.close r
    )
    (fun () ->
       Async_eio.run_async (fun () ->
          let ( >>= ) = Async_kernel.( >>= ) in
          Async_unix.In_thread.(run ~when_finished:When_finished.Take_the_async_lock)
            (fun () -> Unix.sleepf 0.1)
          >>= fun () ->
          Format.eprintf "+Async code running in thread-pool thread@.";
          Unix.close w;
          Async_kernel.return ()
       )
    );;
+Eio blocking...
+Async code running in thread-pool thread
+Eio ready to read
- : unit = ()
```
