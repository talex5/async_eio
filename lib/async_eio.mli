(** {2 Starting the event loop} *)

type t
(** A token that indicates that {!with_event_loop} has been called.
    Libraries can take an argument of this type to remind applications using the library
    that they need to run the Async event loop. *)

val with_event_loop : (t -> 'a) -> 'a
(** [with_event_loop fn] starts an Async event loop running and then executes [fn t].
    When that finishes, the event loop is stopped. *)

(** {2 Mixing Eio and Async code} *)

val run_eio : (unit -> 'a) -> 'a Async_kernel.Deferred.t 
(** [run_eio fn] allows running Eio code from within an Async function.
    It runs [fn ()] in a new Eio fiber and returns a deferred for the result.
    The new fiber is attached to the Async event loop's switch and will be
    cancelled if the function passed to {!with_event_loop} returns. *)

val run_async : (unit -> 'a Async_kernel.Deferred.t) -> 'a
(** [run_async fn] allows running Async code from within an Eio function.
    Unlike {!Promise.await_deferred}, it copes with exceptions raised by [fn].
    This can only be used while the event loop created by {!with_event_loop} is still running. *)

module Promise : sig
  val await_deferred : 'a Async_kernel.Deferred.t -> 'a
  (** [await_deferred x] allows an Eio fiber to wait for an Async deferred [x] to become determined,
      much like {!Eio.Promise.await} does for Eio promises.
      This can only be used while the event loop created by {!with_event_loop} is still running. *)

  val await_eio : 'a Eio.Promise.t -> 'a Async_kernel.Deferred.t
  (** [await_eio p] allows a Async thread to wait for an Eio promise [p] to be resolved.
      This can only be used while the event loop created by {!with_event_loop} is still running. *)

  val await_eio_result : 'a Eio.Promise.or_exn -> 'a Async_kernel.Deferred.t
  (** [await_eio_result] is like [await_eio], but allows failing the Async thread too. *)
end

module Flow : sig
  val source_of_reader : Async_unix.Reader.t -> Eio.Flow.source
  (** [source_of_reader r] is an Eio source that reads from Async reader [r]. *)

  val sink_of_writer : Async_unix.Writer.t -> Eio.Flow.sink
  (** [sink_of_writer r] is an Eio sink that writes to Async writer [w]. *)
end
