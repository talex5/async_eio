(lang dune 2.9)
(name async_eio)
(formatting disabled)
(generate_opam_files true)
(source (github talex5/async_eio))
(authors "Thomas Leonard")
(maintainers "talex5@gmail.com")
(package
 (name async_eio)
 (synopsis "Run Async code within Eio")
 (description "An Async FD watcher that allows running Async within an Eio event loop.")
 (depends
  (eio (>= 0.3))
  async_unix
  (mdx (and (>= 1.10.0) :with-test))
  (eio_main :with-test)))
(using mdx 0.1)
