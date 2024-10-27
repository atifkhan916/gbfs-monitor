variable "aws_region" {
  description = "AWS region"
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name prefix for resources"
  default     = "gbfs-monitor"
}

variable "notification_email" {
  description = "Email address for QuickSight notifications"
  type        = string
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
      name = "mibicitubici"
      url = "https://www.mibicitubici.gob.ar/opendata/gbfs.json"
    },
    {
      name = "nextbike"
      url = "https://gbfs.nextbike.net/maps/gbfs/v2/nextbike_al/gbfs.json"
    }
  ]
}