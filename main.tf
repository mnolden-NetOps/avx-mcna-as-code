# Transit FireNet in AWS
module "transit_firenet_aws" {
  source  = "terraform-aviatrix-modules/aws-transit-firenet/aviatrix"
  version = "5.0.0"

  count = var.deploy_aws ? (var.enable_firenet_on_aws ? 1 : 0) : 0

  name                          = "${var.customer_prefix}${var.aws_prefix}-${var.aws_region_short}-hub"
  prefix                        = false
  suffix                        = true
  cidr                          = var.aws_transit_cidr
  region                        = var.aws_region
  account                       = var.aws_account_name
  instance_size                 = var.aws_firenet_gateway_size
  fw_instance_size              = var.aws_firewall_size
  fw_amount                     = 2
  iam_role_1                    = var.deploy_checkpoint_fw ? null : (var.use_aws_gwlb ? null : var.aws_iam_bootstrap_role)
  bootstrap_bucket_name_1       = var.deploy_checkpoint_fw ? null : (var.use_aws_gwlb ? null : var.aws_bootstrap_bucket)
  user_data_1                   = var.deploy_checkpoint_fw ? data.template_file.checkpoint_fw_init : ""
  ha_gw                         = var.transit_ha
  insane_mode                   = var.hpe
  use_gwlb                      = var.deploy_checkpoint_fw ? false : var.use_aws_gwlb
  enable_egress_transit_firenet = var.egress_transit_firenet
  firewall_image                = var.deploy_checkpoint_fw ? "Check Point CloudGuard IaaS Next-Gen Firewall with Threat Prevention" : "Palo Alto Networks VM-Series Next-Generation Firewall Bundle 1"
  enable_segmentation           = var.segmentation
  tags                          = var.tags
}

# Transit Gateways in AWS
module "transit_aws" {
  source  = "terraform-aviatrix-modules/mc-transit/aviatrix"
  version = "1.1.1"

  count = var.deploy_aws ? (var.enable_firenet_on_aws ? 0 : 1) : 0

  cloud               = "AWS"
  name                = "${var.customer_prefix}${var.aws_prefix}-${var.aws_region_short}-hub-transit"
  cidr                = var.aws_transit_cidr
  region              = var.aws_region
  account             = var.aws_account_name
  instance_size       = var.aws_transit_gateway_size
  ha_gw               = var.transit_ha
  insane_mode         = var.hpe
  enable_segmentation = var.segmentation
  single_az_ha        = false
  tags                = var.tags
}

# Spoke Gateways in AWS. Connect to Transit Gateways (or Transit FireNet) in AWS
module "spoke_aws" {
  source  = "terraform-aviatrix-modules/mc-spoke/aviatrix"
  version = "1.1.0"

  count = var.deploy_aws ? length(var.spoke_name_list) : 0

  cloud           = "AWS"
  name            = "${var.customer_prefix}${var.aws_prefix}-${var.aws_region_short}-${var.spoke_name_list[count.index]}-spoke"
  cidr            = var.aws_spoke_cidr_list[count.index]
  region          = var.aws_region
  account         = var.aws_account_name
  instance_size   = var.aws_spoke_gateway_size
  transit_gw      = var.enable_firenet_on_aws ? module.transit_firenet_aws[0].transit_gateway.gw_name : module.transit_aws[0].transit_gateway.gw_name
  ha_gw           = count.index == 0 ? anytrue([var.spoke_ha, var.spoke_ha_first_vpc_only]) : var.spoke_ha
  insane_mode     = var.hpe
  single_ip_snat  = var.source_nat_on_spoke
  single_az_ha    = false
  security_domain = var.segmentation ? var.segmentation_domain_list[count.index] : ""
  tags            = var.tags
}

# Security Groups for EC2 Instances in Spoke VPCs in AWS
resource "aws_security_group" "test_instance_sg" {
  count = var.deploy_aws ? length(var.spoke_name_list) : 0

  name        = "${var.customer_prefix}${var.spoke_name_list[count.index]}-sg"
  description = "Allow SSH from My IP as well as traffic from Private IP addresses"
  vpc_id      = module.spoke_aws[count.index].vpc.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.my_ip_address]
  }
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(var.tags, { Name = "${var.customer_prefix}${var.spoke_name_list[count.index]}-sg" })
}

# Provision an EC2 Instance that will act as "Jump Host" for the environment. This is the only instance accessible in SSH using a Public IP Address
resource "aws_instance" "jump-host" {
  count = var.deploy_aws ? 1 : 0

  ami                         = var.aws_linux2_on_aws_ec2 ? data.aws_ami.aws-linux2.id : data.aws_ami.aws-ubuntu.id
  instance_type               = var.aws_test_ec2_size
  key_name                    = var.aws_key_name
  vpc_security_group_ids      = [aws_security_group.test_instance_sg[local.aws_jumphost_spoke_vpc].id]
  subnet_id                   = module.spoke_aws[local.aws_jumphost_spoke_vpc].vpc.public_subnets[count.index].subnet_id
  associate_public_ip_address = true
  private_ip                  = anytrue([cidrhost(module.spoke_aws[local.aws_jumphost_spoke_vpc].vpc.public_subnets[count.index].cidr, local.aws_test_ec2_jumphostnum) == module.spoke_aws[local.aws_jumphost_spoke_vpc].spoke_gateway.private_ip, cidrhost(module.spoke_aws[local.aws_jumphost_spoke_vpc].vpc.public_subnets[count.index].cidr, local.aws_test_ec2_jumphostnum) == module.spoke_aws[local.aws_jumphost_spoke_vpc].spoke_gateway.ha_private_ip]) ? cidrhost(module.spoke_aws[local.aws_jumphost_spoke_vpc].vpc.public_subnets[count.index].cidr, local.aws_test_ec2_jumphostnum_bis) : cidrhost(module.spoke_aws[local.aws_jumphost_spoke_vpc].vpc.public_subnets[count.index].cidr, local.aws_test_ec2_jumphostnum)
  user_data                   = file(local.aws_user_data_file)
  tags                        = merge(var.tags, { Name = "${var.customer_prefix}${var.aws_prefix}-${var.aws_region_short}-${var.spoke_name_list[local.aws_jumphost_spoke_vpc]}-jump-vm" })
}

resource "aws_instance" "spoke_aws_ec2" {
  count = var.deploy_aws ? length(var.spoke_name_list) : 0

  ami                    = var.aws_linux2_on_aws_ec2 ? data.aws_ami.aws-linux2.id : data.aws_ami.aws-ubuntu.id
  instance_type          = var.aws_test_ec2_size
  key_name               = var.aws_key_name
  vpc_security_group_ids = [aws_security_group.test_instance_sg[count.index].id]
  subnet_id              = module.spoke_aws[count.index].vpc.private_subnets[0].subnet_id
  private_ip             = cidrhost(module.spoke_aws[count.index].vpc.private_subnets[0].cidr, var.aws_test_ec2_hostnum)
  user_data              = file(local.aws_user_data_file)
  tags                   = merge(var.tags, { Name = "${var.customer_prefix}${var.aws_prefix}-${var.aws_region_short}-${var.spoke_name_list[count.index]}-vm" })
}

# Transit FireNet in Azure
module "transit_firenet_azure" {
  source  = "terraform-aviatrix-modules/azure-transit-firenet/aviatrix"
  version = "5.0.1"

  count = var.deploy_azure ? (var.enable_firenet_on_azure ? 1 : 0) : 0

  name                          = "${var.customer_prefix}${var.azure_prefix}-${var.aws_region_short}-hub"
  prefix                        = false
  suffix                        = true
  cidr                          = var.azure_transit_cidr
  region                        = var.azure_region
  account                       = var.azure_account_name
  resource_group                = var.azure_resource_group
  instance_size                 = var.azure_firenet_gateway_size
  fw_instance_size              = var.azure_firewall_size
  fw_amount                     = 2
  bootstrap_storage_name_1      = var.azure_bootstrap_storage
  storage_access_key_1          = var.azure_bootstrap_storage_access_key
  file_share_folder_1           = var.azure_bootstrap_file_share_folder
  ha_gw                         = var.transit_ha
  insane_mode                   = var.hpe
  enable_egress_transit_firenet = var.egress_transit_firenet
  firewall_image                = "Palo Alto Networks VM-Series Next-Generation Firewall Bundle 1"
  enable_segmentation           = var.segmentation
  tags                          = var.tags
}

# Transit Gateways in Azure
module "transit_azure" {
  source  = "terraform-aviatrix-modules/mc-transit/aviatrix"
  version = "1.1.1"

  count = var.deploy_azure ? (var.enable_firenet_on_azure ? 0 : 1) : 0

  cloud                  = "Azure"
  name                   = "${var.customer_prefix}${var.azure_prefix}-${var.azure_region_short}-hub-transit"
  cidr                   = var.azure_transit_cidr
  region                 = var.azure_region
  account                = var.azure_account_name
  resource_group         = var.azure_resource_group
  instance_size          = var.azure_transit_gateway_size
  ha_gw                  = var.transit_ha
  insane_mode            = var.hpe
  enable_segmentation    = var.segmentation
  enable_transit_firenet = var.prepare_firenet_on_azure
  single_az_ha           = false
  tags                   = var.tags
}

# Spoke Gateways in Azure. Connect to Transit Gateways (or Transit FireNet) in Azure
module "spoke_azure" {
  source  = "terraform-aviatrix-modules/mc-spoke/aviatrix"
  version = "1.1.0"

  count = var.deploy_azure ? length(var.spoke_name_list) : 0

  cloud           = "Azure"
  name            = "${var.customer_prefix}${var.azure_prefix}-${var.azure_region_short}-${var.spoke_name_list[count.index]}-spoke"
  cidr            = var.azure_spoke_cidr_list[count.index]
  region          = var.azure_region
  account         = var.azure_account_name
  resource_group  = var.azure_resource_group
  instance_size   = var.azure_spoke_gateway_size
  transit_gw      = var.enable_firenet_on_azure ? module.transit_firenet_azure[0].transit_gateway.gw_name : module.transit_azure[0].transit_gateway.gw_name
  ha_gw           = count.index == 0 ? anytrue([var.spoke_ha, var.spoke_ha_first_vpc_only]) : var.spoke_ha
  insane_mode     = var.hpe
  single_az_ha    = false
  security_domain = var.segmentation ? var.segmentation_domain_list[count.index] : ""
  tags            = var.tags
}


# Azure Network Interfaces used by test Linux Virtual Machines
resource "azurerm_network_interface" "spoke_azure_nic" {
  count = var.deploy_azure ? length(var.spoke_name_list) : 0

  name                = "${var.customer_prefix}${var.azure_prefix}-${var.azure_region_short}-${var.spoke_name_list[count.index]}-nic"
  resource_group_name = var.azure_resource_group
  location            = var.azure_region

  ip_configuration {
    name                          = "${var.customer_prefix}internal-${var.spoke_name_list[count.index]}"
    subnet_id                     = module.spoke_azure[count.index].vpc.private_subnets[0].subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = cidrhost(module.spoke_azure[count.index].vpc.private_subnets[0].cidr, var.azure_test_vm_hostnum)
  }

  depends_on = [azurerm_network_security_group.spoke_azure_nsg]
}

# Azure Network Security Group (NSG) used by test Linux Virtual Machines
resource "azurerm_network_security_group" "spoke_azure_nsg" {
  count = var.deploy_azure ? 1 : 0

  name                = "${var.customer_prefix}${var.azure_prefix}-${var.azure_region_short}-rfc1918-nsg"
  resource_group_name = var.azure_resource_group
  location            = var.azure_region

  security_rule {
    name                       = "Deny-HTTP"
    priority                   = 150
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "80"
    destination_port_range     = "80"
    source_address_prefix      = "10.0.0.0/8"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "AllowRFC1918-1"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.0.0.0/8"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "AllowRFC1918-2"
    priority                   = 250
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "172.16.0.0/12"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "AllowRFC1918-3"
    priority                   = 300
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "192.168.0.0/16"
    destination_address_prefix = "*"
  }

  tags = var.tags
}

# Associate Azure NSG to the Azure NIC used by test Linux Virtual Machines
resource "azurerm_network_interface_security_group_association" "spoke_azure_nsg_asso" {
  count = var.deploy_azure ? length(var.spoke_name_list) : 0

  network_interface_id      = azurerm_network_interface.spoke_azure_nic[count.index].id
  network_security_group_id = azurerm_network_security_group.spoke_azure_nsg[0].id
}

# Azure Linux Virtual Machines used as test VMs
resource "azurerm_linux_virtual_machine" "spoke_azure_vm" {
  count = var.deploy_azure ? length(var.spoke_name_list) : 0

  name                  = "${var.customer_prefix}${var.azure_prefix}-${var.azure_region_short}-${var.spoke_name_list[count.index]}-vm"
  resource_group_name   = var.azure_resource_group
  location              = var.azure_region
  size                  = var.azure_test_vm_size
  admin_username        = var.azure_test_vm_user
  computer_name         = "azure-${var.spoke_name_list[count.index]}-vm"
  custom_data           = base64encode(data.template_file.linux_vm_cloud_init.rendered)
  network_interface_ids = [azurerm_network_interface.spoke_azure_nic[count.index].id]
  tags                  = merge(var.tags, { Name = "${var.customer_prefix}${var.azure_prefix}-${var.azure_region_short}-${var.spoke_name_list[count.index]}-vm" })

  admin_ssh_key {
    username   = var.azure_test_vm_user
    public_key = file("${local.azure_public_key}")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }
}

# Transit Gateways in GCP
module "transit_gcp" {
  source  = "terraform-aviatrix-modules/mc-transit/aviatrix"
  version = "1.1.1"

  count = var.deploy_gcp ? 1 : 0

  cloud               = "GCP"
  name                = "${var.customer_prefix}${var.gcp_prefix}-${var.gcp_region_short}-hub-transit"
  cidr                = var.gcp_transit_cidr
  region              = var.gcp_region
  account             = var.gcp_account_name
  instance_size       = var.gcp_transit_gateway_size
  ha_gw               = var.transit_ha
  insane_mode         = var.hpe
  enable_segmentation = var.segmentation
  single_az_ha        = false
}

# Spoke Gateways in GCP. Connect to Transit Gateways in GCP
module "spoke_gcp" {
  source  = "terraform-aviatrix-modules/mc-spoke/aviatrix"
  version = "1.1.0"

  count = var.deploy_gcp ? length(var.spoke_name_list) : 0

  cloud           = "GCP"
  name            = "${var.customer_prefix}${var.gcp_prefix}-${var.gcp_region_short}-${var.spoke_name_list[count.index]}-spoke"
  cidr            = var.gcp_spoke_cidr_list[count.index]
  region          = var.gcp_region
  account         = var.gcp_account_name
  instance_size   = var.gcp_spoke_gateway_size
  transit_gw      = module.transit_gcp[0].transit_gateway.gw_name
  ha_gw           = count.index == 0 ? anytrue([var.spoke_ha, var.spoke_ha_first_vpc_only]) : var.spoke_ha
  insane_mode     = var.hpe
  single_az_ha    = false
  security_domain = var.segmentation ? var.segmentation_domain_list[count.index] : ""
}

# Google Compute Instances used as test instances
resource "google_compute_instance" "spoke_gcp_vm" {
  count = var.deploy_gcp ? length(var.spoke_name_list) : 0

  name         = "${var.customer_prefix}${var.gcp_prefix}-${var.gcp_region_short}-${var.spoke_name_list[count.index]}-vm"
  machine_type = var.gcp_test_instance_size
  zone         = var.gcp_zone

  boot_disk {
    initialize_params {
      image = "ubuntu-minimal-1804-lts"
    }
  }

  network_interface {
    network    = "${var.customer_prefix}${var.gcp_prefix}-${var.gcp_region_short}-${var.spoke_name_list[count.index]}-spoke"
    subnetwork = "${var.customer_prefix}${var.gcp_prefix}-${var.gcp_region_short}-${var.spoke_name_list[count.index]}-spoke"
    network_ip = cidrhost(module.spoke_gcp[count.index].vpc.subnets[0].cidr, var.gcp_test_instance_hostnum)
  }

  metadata_startup_script = file(local.user_data_file)

  tags = ["${var.customer_prefix}internal"]
}

resource "google_compute_firewall" "lab-traffic" {
  count = var.deploy_gcp ? length(var.spoke_name_list) : 0

  name    = "${var.customer_prefix}allow-internal-traffic-${module.spoke_gcp[count.index].vpc.name}"
  network = module.spoke_gcp[count.index].vpc.name

  allow {
    protocol = "all"
  }

  source_ranges = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  target_tags   = ["${var.customer_prefix}internal"]
}

resource "time_sleep" "wait_for_fw_to_come_up" {
  count = anytrue([alltrue([var.enable_firenet_on_aws, !var.use_aws_gwlb]), var.enable_firenet_on_azure, var.enable_firenet_on_gcp]) ? 1 : 0
  depends_on = [
    module.transit_firenet_aws,
    module.transit_firenet_azure
  ]
  create_duration = "900s"
}

resource "time_sleep" "wait_for_fw_to_come_up_in_azure" {
  count = var.enable_firenet_on_azure ? 1 : 0
  depends_on = [
    module.transit_firenet_azure,
    time_sleep.wait_for_fw_to_come_up
  ]
  create_duration = "300s"
}

# Connect Transit Gateways in AWS and Azure
module "multi_cloud_transit_peering" {
  source  = "terraform-aviatrix-modules/mc-transit-peering/aviatrix"
  version = "1.0.4"

  transit_gateways = compact([
    var.deploy_aws ? (var.enable_firenet_on_aws ? module.transit_firenet_aws[0].transit_gateway.gw_name : module.transit_aws[0].transit_gateway.gw_name) : "",
    var.deploy_azure ? (var.enable_firenet_on_azure ? module.transit_firenet_azure[0].transit_gateway.gw_name : module.transit_azure[0].transit_gateway.gw_name) : "",
    var.deploy_gcp ? module.transit_gcp[0].transit_gateway.gw_name : ""
  ])

  excluded_cidrs = [
    "0.0.0.0/0",
  ]
}

# Create Aviatrix Segmentation Security Domains
resource "aviatrix_segmentation_security_domain" "seg_dom" {
  count = length(var.segmentation_domain_list)

  domain_name = var.segmentation_domain_list[count.index]
}

# Create Aviatrix Segmentation Security Domain Connection Policies : Any-to-Any
resource "aviatrix_segmentation_security_domain_connection_policy" "seg_dom_con_pol" {
  count = length(var.segmentation_domain_list)

  domain_name_1 = var.segmentation_domain_list[count.index]
  domain_name_2 = count.index == length(var.segmentation_domain_list) - 1 ? var.segmentation_domain_list[0] : var.segmentation_domain_list[count.index + 1]

  depends_on = [aviatrix_segmentation_security_domain.seg_dom]
}

# S2C Transit Gateways in AWS
module "s2c_transit_aws" {
  source  = "terraform-aviatrix-modules/mc-transit/aviatrix"
  version = "1.1.1"

  count = alltrue([var.deploy_aws, var.enable_s2c_on_aws]) ? 1 : 0

  cloud = "AWS"
  name                          = "${var.customer_prefix}onprem"
  cidr                          = var.aws_s2c_cidr
  region                        = var.aws_s2c_region
  account                       = var.aws_account_name
  instance_size                 = var.aws_transit_gateway_size
  ha_gw                         = var.transit_ha
  insane_mode                   = var.hpe
  enable_segmentation           = var.segmentation
  enable_advertise_transit_cidr = true
  single_az_ha                  = false
  tags                          = var.tags
}

# Create an Aviatrix Transit External Device Connection - "Cloud" side
resource "aviatrix_transit_external_device_conn" "cloud_conn" {
  count = alltrue([var.deploy_aws, var.enable_s2c_on_aws]) ? 1 : 0

  vpc_id                    = var.enable_firenet_on_aws ? module.transit_firenet_aws[0].vpc.vpc_id : module.transit_aws[0].vpc.vpc_id
  connection_name           = "to-on-prem"
  gw_name                   = var.enable_firenet_on_aws ? module.transit_firenet_aws[0].transit_gateway.gw_name : module.transit_aws[0].transit_gateway.gw_name
  connection_type           = "bgp"
  tunnel_protocol           = "IPsec"
  enable_ikev2              = true
  bgp_local_as_num          = "65001"
  bgp_remote_as_num         = "65002"
  remote_gateway_ip         = module.s2c_transit_aws[count.index].transit_gateway.eip
  pre_shared_key            = "canadiens"
  local_tunnel_cidr         = var.transit_ha ? "169.254.0.1/30,169.254.1.1/30" : "169.254.0.1/30"
  remote_tunnel_cidr        = var.transit_ha ? "169.254.0.2/30,169.254.1.2/30" : "169.254.0.2/30"
  ha_enabled                = var.transit_ha
  backup_bgp_remote_as_num  = var.transit_ha ? "65002" : null
  backup_remote_gateway_ip  = var.transit_ha ? module.s2c_transit_aws[count.index].transit_gateway.ha_eip : null
  backup_pre_shared_key     = var.transit_ha ? "canadiens" : null
  backup_local_tunnel_cidr  = var.transit_ha ? "169.254.10.1/30,169.254.11.1/30" : null
  backup_remote_tunnel_cidr = var.transit_ha ? "169.254.10.2/30,169.254.11.2/30" : null
}

# Create an Aviatrix Transit External Device Connection - "On-Prem" side
resource "aviatrix_transit_external_device_conn" "onprem_conn" {
  count = alltrue([var.deploy_aws, var.enable_s2c_on_aws]) ? 1 : 0

  vpc_id                    = module.s2c_transit_aws[0].vpc.vpc_id
  connection_name           = "to-the-cloud"
  gw_name                   = module.s2c_transit_aws[0].transit_gateway.gw_name
  connection_type           = "bgp"
  tunnel_protocol           = "IPsec"
  enable_ikev2              = true
  bgp_local_as_num          = "65002"
  bgp_remote_as_num         = "65001"
  remote_gateway_ip         = var.enable_firenet_on_aws ? module.transit_firenet_aws[0].transit_gateway.eip : module.transit_aws[0].transit_gateway.eip
  pre_shared_key            = "canadiens"
  local_tunnel_cidr         = var.transit_ha ? "169.254.0.2/30,169.254.10.2/30" : "169.254.0.2/30"
  remote_tunnel_cidr        = var.transit_ha ? "169.254.0.1/30,169.254.10.1/30" : "169.254.0.1/30"
  ha_enabled                = var.transit_ha
  backup_bgp_remote_as_num  = var.transit_ha ? "65001" : null
  backup_remote_gateway_ip  = var.transit_ha ? var.enable_firenet_on_aws ? module.transit_firenet_aws[0].transit_gateway.ha_eip : module.transit_aws[0].transit_gateway.ha_eip : null
  backup_pre_shared_key     = var.transit_ha ? "canadiens" : null
  backup_local_tunnel_cidr  = var.transit_ha ? "169.254.1.2/30,169.254.11.2/30" : null
  backup_remote_tunnel_cidr = var.transit_ha ? "169.254.1.1/30,169.254.11.1/30" : null
}

# Create Aviatrix Segmentation Security Domain Associations for S2C
resource "aviatrix_segmentation_security_domain_association" "s2c-cloud-segmentation" {
  transit_gateway_name = var.enable_firenet_on_aws ? module.transit_firenet_aws[0].transit_gateway.gw_name : module.transit_aws[0].transit_gateway.gw_name
  security_domain_name = aviatrix_segmentation_security_domain.seg_dom[0].domain_name
  attachment_name      = "to-on-prem"

  depends_on = [aviatrix_transit_external_device_conn.cloud_conn]
}

resource "aviatrix_segmentation_security_domain_association" "s2c-on-prem-segmentation" {
  transit_gateway_name = module.s2c_transit_aws[0].transit_gateway.gw_name
  security_domain_name = aviatrix_segmentation_security_domain.seg_dom[0].domain_name
  attachment_name      = "to-the-cloud"

  depends_on = [aviatrix_transit_external_device_conn.onprem_conn]
}

# Security Group for EC2 Instance in S2C VPCs in AWS
resource "aws_security_group" "s2c_instance_sg" {
  provider = aws.s2c
  count    = alltrue([var.deploy_aws, var.enable_s2c_on_aws]) ? 1 : 0

  name        = "${var.customer_prefix}onprem-sg"
  description = "Allow SSH from My IP as well as traffic from Private IP addresses"
  vpc_id      = module.s2c_transit_aws[count.index].vpc.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.my_ip_address]
  }
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(var.tags, { Name = "${var.customer_prefix}onprem-sg" })
}

# Test EC2 instance for on-prem
resource "aws_instance" "s2c_aws_ec2" {
  provider = aws.s2c
  count    = alltrue([var.deploy_aws, var.enable_s2c_on_aws]) ? 1 : 0

  ami                    = data.aws_ami.aws-linux2_s2c.id
  instance_type          = var.aws_test_ec2_size
  key_name               = var.aws_key_name
  vpc_security_group_ids = [aws_security_group.s2c_instance_sg[count.index].id]
  subnet_id              = module.s2c_transit_aws[count.index].vpc.private_subnets[0].subnet_id
  private_ip             = cidrhost(module.s2c_transit_aws[count.index].vpc.private_subnets[0].cidr, var.aws_test_ec2_hostnum)
  user_data              = file(var.aws_linux2_user_data_file)
  tags                   = merge(var.tags, { Name = "${var.customer_prefix}onprem-vm" })
}
