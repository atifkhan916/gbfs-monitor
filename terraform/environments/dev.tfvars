environment = "dev"
aws_region  = "ap-south-1"
notification_email  = "gnegi.business@gmail.com"
quicksight_users = {
  "admin-user" = {
    email     = "gnegi.business@gmail.com"
    role      = "ADMIN"
    namespace = "default"
  }
}

quicksight_admin_user = "admin-user"  # This user will be used for data source permissions