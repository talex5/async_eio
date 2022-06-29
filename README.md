# Async_eio - run Async code from within Eio

***Status***: prototype / proof-of-concept

Async_eio allows running Async and Eio code together in a single domain.
It allows converting existing code to Eio incrementally.

See `lib/async_eio.mli` for the API.


## Testing

You need to clone with submodules, as changes are needed to various libraries:

```
git clone --recursive https://github.com/talex5/async_eio.git
cd async_eio
opam install --deps-only -t .
dune runtest
```

## Porting an Async application to Eio

This guide will show how to migrate an existing Async application or library to Eio.
We'll start with an echo server, based on an example from Real World OCaml.

But first, we'll need to load a few libraries:

```ocaml
# #require "async_kernel";;
# #require "async_unix";;
# #require "core";;
```

### The initial Async version

Here is the initial Async code for a client and a server:

```ocaml
open Core;;
open Async_kernel;;
open Async_unix;;

(* Copy data from [r] to [w]. *)
let handle_client ~r ~w =
  Pipe.transfer ~f:Fun.id
    (Reader.pipe r)
    (Writer.pipe w)

(* Run an echo server on [port]. *)
let run_server ~port =
  Tcp.Server.create
    ~on_handler_error:`Raise
    (Tcp.Where_to_listen.of_port port)
    (fun _addr r w ->
       handle_client ~r ~w >>= fun () ->
       Writer.flushed w
    )

(* Test an echo server on localhost/[port]. *)
let run_client ~port =
  let addr = Tcp.Where_to_connect.of_inet_address (`Inet (Caml.Unix.inet_addr_loopback, port)) in
  Tcp.with_connection addr @@ fun socket r w ->
  Writer.write_line w "Hello";
  Writer.flushed w >>= fun () ->
  Socket.shutdown socket `Send;
  Reader.contents r >>= fun msg ->
  Format.eprintf "Client got: %S@." msg;
  return ();;
```

We can test it like this:

```ocaml
# let port = 8080;;
val port : int = 8080

# Thread_safe.run_in_async_wait_exn (fun () ->
     run_server ~port >>= fun server ->
     run_client ~port >>= fun () ->
     Tcp.Server.close server
    );;
Client got: "Hello\n"
- : unit = ()

# Thread_safe.reset_scheduler ();;
- : unit = ()
```

### Switch the event loop to Eio

The first step is to run the code within an Eio event loop, replacing the uses of `Thread_safe`
but keeping everything else the same:

```ocaml
# #require "eio_main";;
# #require "async_eio";;

# open Eio.Std;;

# Eio_main.run @@ fun env ->
  Async_eio.with_event_loop @@ fun _ ->
  Async_eio.run_async (fun () ->
     run_server ~port >>= fun server ->
     run_client ~port >>= fun () ->
     Tcp.Server.close server
  );;
Client got: "Hello\n"
- : unit = ()
```

### Convert the client

We can now start converting code to Eio.
There are several places we could start.
Let's begin with the client:

```ocaml
let run_client ~net ~port =
  Switch.run @@ fun sw ->
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let flow = Eio.Net.connect ~sw net addr in
  Eio.Flow.copy_string "Hello\n" flow;
  Eio.Flow.shutdown flow `Send;
  let r = Eio.Buf_read.of_flow flow ~max_size:100 in
  let msg = Eio.Buf_read.take_all r in
  traceln "Client got: %S" msg
```

It should still produce the same result:

```ocaml
# Eio_main.run @@ fun env ->
  Async_eio.with_event_loop @@ fun _ ->
  Async_eio.run_async (fun () ->
     run_server ~port >>= fun server ->
     Async_eio.run_eio (fun () -> run_client ~net:env#net ~port) >>= fun () ->
     Tcp.Server.close server
  );;
+Client got: "Hello\n"
- : unit = ()
```

Note that as the client is now Eio code,
we must use `Async_eio.run_eio` to switch back to Eio context from within the async code.
Alternatively, we could use `Async_eio.run_async` twice:

```ocaml
# Eio_main.run @@ fun env ->
  Async_eio.with_event_loop @@ fun _ ->
  let server = Async_eio.run_async (fun () -> run_server ~port) in
  run_client ~net:env#net ~port;
  Async_eio.run_async (fun () -> Tcp.Server.close server);;
+Client got: "Hello\n"
- : unit = ()
```

### Convert the server callback

We can convert `handle_client` to be an Eio function, wrapping Async readers and writers in Eio flows,
while still using Async to run the server:

```ocaml
let handle_client ~r ~w =
  Async_eio.run_eio @@ fun () ->
  let r = Async_eio.Flow.source_of_reader r in
  let w = Async_eio.Flow.sink_of_writer w in
  Eio.Flow.copy r w
```

The server remains the same (but we need to define it again so it refers to our new `handle_client`):

```ocaml
let run_server ~port =
  Tcp.Server.create
    ~on_handler_error:`Raise
    (Tcp.Where_to_listen.of_port port)
    (fun _addr r w ->
       handle_client ~r ~w >>= fun () ->
       Writer.flushed w
    )
```

```ocaml
# Eio_main.run @@ fun env ->
  Async_eio.with_event_loop @@ fun _ ->
  let server = Async_eio.run_async (fun () -> run_server ~port) in
  run_client ~net:env#net ~port;
  Async_eio.run_async (fun () -> Tcp.Server.close server);;
+Client got: "Hello\n"
- : unit = ()
```

### Convert the server

Finally, we can convert the server to Eio and drop all uses of Async and Async_eio:

```ocaml
let handle_client flow =
  Eio.Flow.copy flow flow

let run_server ~sw socket =
  while true do
    Eio.Net.accept_fork ~sw ~on_error:raise socket (fun flow _addr ->
        handle_client flow
    )
  done

let main net =
  Switch.run @@ fun sw ->
  let socket = Eio.Net.listen net ~sw ~backlog:5 (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
  Fiber.first
    (fun () -> run_server ~sw socket)
    (fun () -> run_client ~net ~port)
```

The structure has changed a little here.
In the Async version, the server starts running in the background and we must remember to stop it.
In Eio, we instead use a switch to bound the lifetime of the server,
and it seems more natural to create the socket outside of `run_server`.

```ocaml
# Eio_main.run @@ fun env ->
  main env#net;;
+Client got: "Hello\n"
- : unit = ()
```

### Key points

- Start by using `Async_eio.with_event_loop` to run Async, while keeping the rest of the code the same.

- Update your program piece by piece, using `Async_eio` when moving between Eio and Async contexts.

- Never call Eio code directly from Async code. Wrap it with `Async_eio.run_eio`.
  Simply wrapping the result of an Eio call with `Async.return` is NOT safe.

- Almost all uses of Async promises (`Deferred.t`) should disappear
  (do not blindly replace each Async deferred with an Eio promise).

- You don't have to do the conversion in any particular order.

- You may need to make other changes to your API. In particular:

  - External resources (such as the network and the filesystem) should be passed as inputs to Eio code.

  - Take a `Switch.t` argument if your function creates fibers or file handles that out-live the function.

  - If you are writing a library that requires `Async_eio`, consider having its main function (if any)
    take a value of type `Async_eio.t`. This will remind users of the library to initialise Async_eio first.

## Limitations

- Async code can only run in a single domain, and using `Async_eio` does not change this.
  You can only run Async code in the domain that ran `Async_eio.with_event_loop`.

- `Async_eio` does not make your Async programs run faster than before.
  Async jobs are still run by Async, and do not take advantage of Eio's `io_uring` support, for example.
