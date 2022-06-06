(** This is almost identical to Async_unix's epoll_file_descr_watcher.ml, except that it uses Eio_unix to wait for
    the epollfd to become ready, allowing other Eio jobs to run. *)

open! Core

type 'a additional_create_args = timerfd:Linux_ext.Timerfd.t -> 'a

include
  Async_unix.File_descr_watcher_intf.S
  with type 'a additional_create_args := 'a additional_create_args
