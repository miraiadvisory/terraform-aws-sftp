# resource "aws_network_interface" "this" {
#   subnet_id = var.subnet_id
# }

resource "aws_eip" "this" {
  vpc = true
}