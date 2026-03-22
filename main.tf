locals {
  dns_data = yamldecode(file("${path.module}/records.yaml"))
  zones    = distinct([for s in local.dns_data.services : s.zone])
}

resource "google_dns_record_set" "public" {
  for_each     = { for s in local.dns_data.services : "${s.zone}-${s.name}-${s.type}" => s }
  
  name         = "${each.value.name}.${each.value.zone}."
  type         = each.value.type
  ttl          = 300
  managed_zone = "gentoomaniac-public"

  rrdatas      = [each.value.value] 
}

resource "local_file" "coredns_zones" {
  for_each = toset(local.zones)

  filename = "${path.module}/zones/${each.key}.db"
  content  = templatefile("${path.module}/templates/zone.tmpl", {
    domain_name  = each.key
    serial       = formatdate("YYYYMMDDhh", timestamp())
    services     = [for s in local.dns_data.services : s if s.zone == each.key]
    
    default_ttl  = "300"
    refresh      = "3600"
    retry        = "600"
    expire       = "604800"
    minimum_ttl  = "60"
  })
}

