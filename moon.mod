name = "oyjh0381/moonoci"

version = "0.2.0"

readme = "README.mbt.md"

repository = "https://github.com/oyjh0381/MoonBit"

license = "Apache-2.0"

keywords = [ "oci", "container-image", "reproducible-build", "tar" ]

preferred_target = "native"

description = "Deterministic OCI image layout builder and validator for MoonBit"

import {
  "moonbitlang/x@0.5.5",
  "hustcer/fzip@0.8.8",
  "moonbitlang/async@0.20.6",
  "moonbitlang/quickcheck@0.15.1",
}
