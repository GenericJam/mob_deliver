import Config

# Library-local config for this repo's own dev/test runs; host apps
# configure :mob_deliver in their own config.
if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")),
  do: import_config("#{config_env()}.exs")
