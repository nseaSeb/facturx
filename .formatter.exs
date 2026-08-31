[
  # dev/ holds `mix facturx.harness`; it is compiled in :dev only, which is not a
  # reason for it to escape the gates this project asks of every other file.
  inputs: ["{mix,.formatter}.exs", "{config,dev,lib,test}/**/*.{ex,exs}"]
]
