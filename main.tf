locals {
  # Read the single source of truth
  dns_data = yamldecode(file("${path.module}/records.yaml"))

  # 1. Expand the YAML and apply the default flags
  flat_records = flatten([
    for s in local.dns_data.services : [
      for z in s.zones : {
        name    = s.name
        zone    = z
        type    = s.type
        value   = s.value
        # Explicit opt-in required for reverse and public records now
        reverse = lookup(s, "reverse", false) 
        public  = lookup(s, "public", false)
      }
    ]
  ])

  # 2. Get a list of unique forward zones (e.g., gentoomaniac.net, srv.gentoomaniac.net)
  forward_zones = distinct([for r in local.flat_records : r.zone])

  # 3. Auto-generate PTR records from 'A' records where reverse == true
  ptr_records = [
    for r in local.flat_records : {
      name  = split(".", r.value)[3]     # Extracts '9' from '10.1.1.9'
      type  = "PTR"
      value = "${r.name}.${r.zone}."     # Creates 'sto-infra-a1.sto.gentoomaniac.net.'
    }
    if r.type == "A" && r.reverse && can(regex("^10\\.1\\.1\\.\\d+$", r.value))
  ]
  
  # Auto-generate a fresh serial number for CoreDNS every run
  serial = formatdate("YYYYMMDDhh", timestamp())
}

# ==========================================
# PUBLIC DNS (Google Cloud DNS)
# ==========================================
resource "google_dns_record_set" "public" {
  # ONLY create this resource if the 'public' flag is explicitly true
  for_each     = { for r in local.flat_records : "${r.zone}-${r.name}-${r.type}" => r if r.public }
  
  name         = "${each.value.name}.${each.value.zone}."
  type         = each.value.type
  ttl          = 300
  managed_zone = "gentoomaniac-public"
  rrdatas      = [each.value.value]
}

# ==========================================
# INTERNAL FORWARD ZONES (CoreDNS)
# ==========================================
resource "local_file" "forward_zones" {
  for_each = toset(local.forward_zones)

  filename = "${path.module}/zones/${each.key}.db"
  content  = templatefile("${path.module}/templates/zone.tmpl", {
    domain_name = each.key
    serial      = local.serial
    # Internal CoreDNS gets all records for this specific zone
    services    = [for r in local.flat_records : r if r.zone == each.key]
  })
}

# ==========================================
# INTERNAL REVERSE ZONE (CoreDNS)
# ==========================================
resource "local_file" "reverse_zone" {
  filename = "${path.module}/zones/10.1.1.db"
  content  = templatefile("${path.module}/templates/zone.tmpl", {
    domain_name = "1.1.10.in-addr.arpa"
    serial      = local.serial
    # Feed in the dynamically generated PTR list
    services    = local.ptr_records
  })
}
