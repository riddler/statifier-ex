### Changed

- The core `{:done, %Statifier.Effect.Done{}}` effect now carries
  `configuration`, the full configuration as it stood at exit, so a consumer
  can observe the terminal position without switching tracing on.
