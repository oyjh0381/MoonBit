# Version and strictly validate build specifications

MoonOCI build specifications will require `schemaVersion: 1` and reject unknown fields, while OCI documents being inspected remain tolerant of unknown fields and media types as required by the ecosystem. Strict build-spec parsing sacrifices effortless forward compatibility, but it prevents misspelled security- or runtime-sensitive settings from being silently ignored; incompatible revisions must introduce a new schema version.
