environment = "dev"
aws_region  = "ap-south-1"
notification_email  = "gnegi.business@gmail.com"
quicksight_users = {
  "adminuser" = {
    email     = "atifkhan916@gmail.com"
    role      = "ADMIN"
    namespace = "default"
  }
}

quicksight_admin_user = "adminuser"  # This user will be used for data source permissions