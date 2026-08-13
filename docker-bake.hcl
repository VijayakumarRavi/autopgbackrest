variable "APP" {
  default = "ghcr.io/vijayakumarravi/autopgbackrest"
}

variable "SOURCE" {
  default = "https://github.com/VijayakumarRavi/autopgbackrest"
}

variable "SUPERCRONIC_VERSION" {
  # renovate: datasource=github-releases depName=aptible/supercronic
  default = "v0.2.44"
}

function "pg_tags" {
  params = []
  result = [
    # renovate: datasource=docker depName=postgres
    "18.3",
    # renovate: datasource=docker depName=postgres
    "17.9",
    # renovate: datasource=docker depName=postgres
    "16.13",
    # renovate: datasource=docker depName=postgres
    "15.19",
    # renovate: datasource=docker depName=postgres
    "14.22"
  ]
}

group "default" {
  targets = ["image"]
}

target "image" {
  name     = "image-${replace(tag, ".", "-")}"

  matrix = {
    tag = pg_tags()
  }
  args = {
    POSTGRES_TAG = "${tag}"
    SUPERCRONIC_VERSION = "${SUPERCRONIC_VERSION}"
  }

  labels = {
    "org.opencontainers.image.source" = "${SOURCE}"
    "org.opencontainers.image.base.name" = "docker.io/library/postgres:${tag}"
    "org.opencontainers.image.version" = "${tag}"
    "org.opencontainers.image.description" = "Automated pgBackRest Docker image for PostgreSQL ${tag}"
  }

  tags = tag == pg_tags()[0] ? [
    "${APP}:${tag}",
    "${APP}:${split(".", tag)[0]}",
    "${APP}:latest"
  ] : [
    "${APP}:${tag}",
    "${APP}:${split(".", tag)[0]}"
  ]

  cache-from = ["type=registry,ref=${APP}:buildcache"]
  cache-to   = ["type=registry,ref=${APP}:buildcache,mode=max,oci-mediatypes=true"]
  platforms  = ["linux/amd64", "linux/arm64", "linux/arm/v7"]
}
