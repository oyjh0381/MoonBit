name = "oyjh0381/moonoci"

version = "0.1.3"

readme = "README.mbt.md"

repository = "https://github.com/oyjh0381/MoonBit"

license = "Apache-2.0"

keywords = [ "oci", "container-image", "reproducible-build", "tar" ]

preferred_target = "native"

description = "Deterministic OCI image layout builder and validator for MoonBit"

import {
  "moonbitlang/x@0.4.49",
  "hustcer/fzip@0.8.6",
  "moonbitlang/async@0.20.4",
  "moonbitlang/quickcheck@0.14.0",
}
