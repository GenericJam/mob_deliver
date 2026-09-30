import Config

# Keep the application-started store out of $HOME during tests; tests that
# exercise the store start their own instances on per-test tmp dirs.
config :mob_deliver, root: Path.join(System.tmp_dir!(), "mob_deliver_test_app")
