ExUnit.start()

# postgres_integration excluded like every other app — media_service was the ONE app missing it, which
# made a @moduletag :postgres_integration meaningless here: the suite ran in the Docker-free job (red
# in CI with no database, green locally whenever a Postgres container happened to be up — the exact
# it-works-on-my-machine gap that hides real failures).
ExUnit.configure(exclude: [postgres_integration: true, http_integration: true])
