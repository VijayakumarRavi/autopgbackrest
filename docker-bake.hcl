variable "APP" {
  default = "ghcr.io/vijayakumarravi/autopgbackrest"
}

variable "SUPERCRONIC_VERSION" {
  # renovate: datasource=github-releases depName=aptible/supercronic
  default = "v0.2.36"
}

variable "SOURCE" {
  default = "https://github.com/VijayakumarRavi/autopgbackrest"
}

variable "PG_TAGS" {
  default = [
    # v18
    "18.1", "18",
    # v17
    "17.7", "17",
    # v16
    "16.11", "16",
    # v15
    "15.15", "15",
    # v14
    "14.20", "14",
  ]
}

group "default" {
  targets = ["image"]
}

target "image" {
  name = "image-${replace(tag, ".", "-")}"
  matrix = {
    tag = PG_TAGS
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

  tags = ["${APP}:${tag}"]
  platforms = [
    "linux/amd64",
    "linux/arm64",
    "linux/arm/v7"
  ]
}