open Eio.Std

module Deferred = Async_kernel.Deferred

type t = {
  sw : Switch.t;
  jobs : (unit -> unit) Eio.Stream.t;   (* Functions to run in Eio's systhread *)
}

(* While the event loop is running, this is the switch that contains any fibers created from Async contexts.
   Async does not use structured concurrency, so it can spawn background threads without explicitly taking a
   switch argument, which is why we need to use a global variable here. *)
let t_ref = ref None

let t () =
  match !t_ref with
  | Some t -> t
  | None -> Fmt.failwith "Must be called from within Async_eio.with_event_loop!"

let set_async_integration x =
  try Eio.Private.Effect.perform (Eio_unix.Private.Set_async_integration x)
  with Unhandled -> failwith "Not running an async-compatible Eio event loop"

let with_event_loop fn =
  Switch.run @@ fun sw ->
  if Option.is_some !t_ref then invalid_arg "Async_eio event loop already running";
  Switch.on_release sw (fun () -> t_ref := None);
  let jobs = Eio.Stream.create max_int in       (* Unbounded, as adding must not block as not in Eio thread *)
  let t = { sw; jobs } in
  t_ref := Some t;
  (* Run [fn] concurrently with the async scheduler.
     When [fn] returns, [Fibre.first] will cancel the async scheduler. *)
  Fiber.first
    (fun () -> fn t)
    (fun () ->
       Fiber.both
         (fun () ->
            (* Run the main async thread *)
            let file_descr_watcher = Async_unix.Scheduler.Which_watcher.Custom
                (module Epoll_file_descr_watcher_eio : Async_unix.Scheduler.Which_watcher.Custom.S) in
            try
              Core.never_returns @@ Async_unix.Scheduler.go_main ~raise_unhandled_exn:true ~file_descr_watcher ()
                ~main:(fun () ->
                    let async_sched = Async_unix.Scheduler.t () in
                    set_async_integration @@ Some {
                      lock = (fun () -> Async_unix.Scheduler.lock async_sched);
                      unlock = (fun () -> Async_unix.Scheduler.unlock async_sched);
                    };
                    Switch.on_release sw (fun () -> set_async_integration None);
                  )
            with ex ->
              Fiber.check ();   (* Check if we were cancelled *)
              raise ex          (* Otherwise, report the fault *)
         )
         (fun () ->
            (* Collect Eio jobs submitted from Async threads *)
            while true do
              let job = Eio.Stream.take t.jobs in
              job ();
            done
         );
       assert false
    )

let check_async_is_running () =
  ignore (t () : t)

let run_async fn =
  check_async_is_running ();
  let p, r = Promise.create () in
  (* Promise.resolve can be run safely from a non-eio thread. *)
  Deferred.upon (Async_kernel.try_with fn) (Promise.resolve r);
  Promise.await_exn p

let run_eio fn =
  Deferred.create (fun ivar ->
      let monitor = Async_kernel.Monitor.current () in
      (* We might be running in an async thread-pool thread, which does not have
         access to the Eio effect handler, so ask the main thread to run the Eio bits. *)
      let t = t () in
      Eio.Stream.add t.jobs (fun () ->
          (* We're now running in an Eio fiber. *)
          Fiber.fork ~sw:t.sw (fun () ->
              match fn () with
              | x -> Async_kernel.Ivar.fill ivar x
              | exception ex ->
                Async_kernel.Monitor.send_exn monitor ex ~backtrace:`Get 
            );
        )
    )

module Promise = struct
  let await_deferred d =
    let p, r = Promise.create () in
    Deferred.upon d (Promise.resolve r);
    Promise.await p

  let await_eio p =
    run_eio (fun () -> Promise.await p)

  let await_eio_result p =
    run_eio (fun () -> Promise.await_exn p)
end

module Flow = struct
  open Async_unix

  let source_of_reader r =
    object
      inherit Eio.Flow.source

      method read_into buf =
        match
          run_async (fun () ->
              let { Cstruct.buffer; off; len } = buf in
              Reader.read_bigsubstring r (Core.Bigsubstring.create ~pos:off ~len buffer)
            )
        with
        | `Ok n -> n
        | `Eof -> raise_notrace End_of_file
    end

  let sink_of_writer w =
    object
      inherit Eio.Flow.sink

      method copy src =
        let buf = Cstruct.create 4096 in
        try
          while true do
            let len = Eio.Flow.read src buf in
            run_async (fun () ->
                let { Cstruct.buffer; off; _ } = buf in
                Writer.write_bigsubstring w (Core.Bigsubstring.create ~pos:off ~len buffer);
                Writer.flushed_or_failed_unit w     (* Is this right? How are you supposed to do back-pressure? *)
              )
          done
        with End_of_file -> ()
    end
end

