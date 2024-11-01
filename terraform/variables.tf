variable "environment" {
  description = "Deployment environment (dev/prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "project_name" {
  description = "Project name prefix for resources"
  default     = "gbfs-monitor"
}

variable "gbfs_providers" {
  description = "List of GBFS providers to monitor"
  type = list(object({
    name = string
    url = string
  }))
  default = [
    {
      name = "careem_bike"
      url = "https://dubai.publicbikesystem.net/customer/gbfs/v2/gbfs.json"
    },
    {
      name = "Ecobici"
      url = "https://buenosaires.publicbikesystem.net/ube/gbfs/v1/"
    },
    {
      name = "nextbike"
      url = "https://gbfs.nextbike.net/maps/gbfs/v2/nextbike_al/gbfs.json"
    }
  ]
}