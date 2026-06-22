locals {
  tables = {
    users = {
      name     = "${var.name_prefix}-users"
      hash_key = "userId"
    }
    slots = {
      name     = "${var.name_prefix}-slots"
      hash_key = "slotId"
    }
    bookings = {
      name     = "${var.name_prefix}-bookings"
      hash_key = "bookingId"
    }
    payments = {
      name     = "${var.name_prefix}-payments"
      hash_key = "paymentId"
    }
    notifications = {
      name     = "${var.name_prefix}-notifications"
      hash_key = "notificationId"
    }
  }
}

resource "aws_dynamodb_table" "this" {
  for_each = local.tables

  name         = each.value.name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = each.value.hash_key

  attribute {
    name = each.value.hash_key
    type = "S"
  }

  point_in_time_recovery {
    enabled = var.point_in_time_recovery
  }

  server_side_encryption {
    enabled = true
  }

  deletion_protection_enabled = var.deletion_protection_enabled
  tags                        = merge(var.tags, { Name = each.value.name })
}
