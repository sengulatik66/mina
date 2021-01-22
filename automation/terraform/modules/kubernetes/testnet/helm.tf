provider helm {
  alias = "testnet_deploy"
  kubernetes {
    config_context  = var.k8s_context
  }
}

data "local_file" "genesis_ledger" {
  # genesis_ledger.json is not required when generate_and_upload_artifacts is set to false
  filename = var.generate_and_upload_artifacts ? "genesis_ledger.json" : "/dev/null"
  depends_on = [
    null_resource.block_producer_key_generation
  ]
}

data "local_file" "libp2p_peers" {
  for_each = toset([ for config in var.block_producer_configs : config.name ])
  filename = "../../../keys/libp2p/${var.testnet_name}/${each.key}"
  depends_on = [
    null_resource.block_producer_key_generation
  ]
}

locals {
  use_local_charts = false
  mina_helm_repo   = "https://coda-charts.storage.googleapis.com"

  seed_peers = [
    "/dns4/seed-node.${var.testnet_name}/tcp/${var.seed_port}/p2p/${split(",", var.seed_discovery_keypairs[0])[2]}"
  ]

  static_peers = { for index, name in keys(data.local_file.libp2p_peers) :
    name => {
      full_peer = "/dns4/${name}.${var.testnet_name}/tcp/${var.block_producer_starting_host_port + index }/p2p/${trimspace(data.local_file.libp2p_peers[name].content)}",
      port      = var.block_producer_starting_host_port + index
      name      = name
    }
  }

  coda_vars = {
    runtimeConfig      = var.generate_and_upload_artifacts ? data.local_file.genesis_ledger.content : var.runtime_config
    image              = var.coda_image
    privkeyPass        = var.block_producer_key_pass
    seedPeers          = concat(
      var.additional_seed_peers,
      local.seed_peers,
      [ for name in keys(local.static_peers) : local.static_peers[name].full_peer ]
    )
    logLevel           = var.log_level
    logSnarkWorkGossip = var.log_snark_work_gossip
    uploadBlocksToGCloud = var.upload_blocks_to_gcloud
  }
  
  coda_network_services_vars = {
    restartEveryMins = var.restart_nodes_every_mins
    restartNodes = var.restart_nodes
    makeReports = var.make_reports
    makeReportEveryMins = var.make_report_every_mins
    makeReportDiscordWebhookUrl = var.make_report_discord_webhook_url
    makeReportAccounts = var.make_report_accounts
  }

  seed_vars = {
    testnetName = var.testnet_name
    coda        = {
      runtimeConfig      = local.coda_vars.runtimeConfig
      image              = var.coda_image
      privkeyPass        = var.block_producer_key_pass
      seedPeers          = var.additional_seed_peers
      logLevel           = var.log_level
      logSnarkWorkGossip = var.log_snark_work_gossip
      ports = {
        client  = "8301"
        graphql = "3085"
        metrics = "8081"
        p2p     = var.seed_port
      }
    }
    seed        = {
      active = true
      discovery_keypair = var.seed_discovery_keypairs[0]
    }
    codaNetworkServicesConfig = local.coda_network_services_vars
  }

  block_producer_vars = {
    testnetName = var.testnet_name

    coda = local.coda_vars

    userAgent = {
      image         = var.coda_agent_image
      minFee        = var.agent_min_fee
      maxFee        = var.agent_max_fee
      minTx         = var.agent_min_tx
      maxTx         = var.agent_max_tx
      txBatchSize   = var.agent_tx_batch_size
      sendEveryMins = var.agent_send_every_mins
      ports         = { metrics: 8000 }
    }

    bots = {
      image  = var.coda_bots_image
      faucet = {
        amount = var.coda_faucet_amount
        fee    = var.coda_faucet_fee
      }
    }

    blockProducerConfigs = [
      for index, config in var.block_producer_configs: {
        name                 = config.name
        class                = config.class
        externalPort         = local.static_peers[config.name].port
        runWithUserAgent     = config.run_with_user_agent
        runWithBots          = config.run_with_bots
        enableGossipFlooding = config.enable_gossip_flooding
        privateKeySecret     = config.private_key_secret
        libp2pSecret         = config.libp2p_secret
        enablePeerExchange   = config.enable_peer_exchange
        isolated             = config.isolated
      }
    ]
  }
  
  snark_worker_vars = {
    testnetName = var.testnet_name
    coda = local.coda_vars 
    worker = {
      active = true
      numReplicas = var.snark_worker_replicas
    }
    coordinator = {
      active = true
      deployService = true
      publicKey   = var.snark_worker_public_key
      snarkFee    = var.snark_worker_fee
      hostPort    = var.snark_worker_host_port
    }
  }

  archive_node_vars = {
    testnetName = var.testnet_name
    coda = {
      image         = var.coda_image
      seedPeers     = concat(var.additional_seed_peers, local.seed_peers)
      runtimeConfig = local.coda_vars.runtimeConfig
    }
    archive = {
      image = var.coda_archive_image
      remoteSchemaFile = var.mina_archive_schema
    }
    postgresql = {
      persistence = {
        enabled = var.archive_persistence_enabled
        storageClass = "${var.cluster_region}-${var.archive_persistence_class}-${lower(var.archive_persistence_reclaim_policy)}"
        accessModes = var.archive_persistence_access_modes
        size = var.archive_persistence_size
      }
      primary = {
        affinity = {
          nodeAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = {
              nodeSelectorTerms = [
                {
                  matchExpressions = [
                    {
                      key = "cloud.google.com/gke-preemptible"
                      operator = "NotIn"
                      values = ["true"]
                    }
                  ]
                }
              ]
            }
          }
        }
      }
    }
  }
  
}

output static_peers {
  value = local.static_peers
}

# Cluster-Local Seed Node

resource "kubernetes_role_binding" "helm_release" {
  metadata {
    name      = "admin-role"
    namespace = kubernetes_namespace.testnet_namespace.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = kubernetes_namespace.testnet_namespace.metadata[0].name
  }
}

resource "helm_release" "seed" {
  provider   = helm.testnet_deploy

  name        = "${var.testnet_name}-seed"
  repository  = local.use_local_charts ? "" : local.mina_helm_repo
  chart       = local.use_local_charts ? "../../../../helm/seed-node" : "seed-node"
  version     = "0.4.5"
  namespace   = kubernetes_namespace.testnet_namespace.metadata[0].name
  values = [
    yamlencode(local.seed_vars)
  ]
  wait        = false
  timeout     = 600
  depends_on  = [
    kubernetes_role_binding.helm_release,
    null_resource.block_producer_uploads,
  ]
}


# Block Producer

resource "helm_release" "block_producers" {
  provider   = helm.testnet_deploy

  name        = "${var.testnet_name}-block-producers"
  repository  = local.use_local_charts ? "" : local.mina_helm_repo
  chart       = local.use_local_charts ? "../../../../helm/block-producer" : "block-producer"
  version     = "0.4.5"
  namespace   = kubernetes_namespace.testnet_namespace.metadata[0].name
  values = [
    yamlencode(local.block_producer_vars)
  ]
  wait        = false
  timeout     = 600
  depends_on  = [helm_release.seed]
}

# Snark Worker

resource "helm_release" "snark_workers" {
  provider   = helm.testnet_deploy

  name        = "${var.testnet_name}-snark-worker"
  repository  = local.use_local_charts ? "" : local.mina_helm_repo
  chart       = local.use_local_charts ? "../../../../helm/snark-worker" : "snark-worker"
  version     = "0.4.5"
  namespace   = kubernetes_namespace.testnet_namespace.metadata[0].name
  values = [
    yamlencode(local.snark_worker_vars)
  ]
  wait        = false
  timeout     = 600
  depends_on  = [helm_release.seed]
}

# Archive Node

resource "helm_release" "archive_node" {
  provider   = helm.testnet_deploy

  count       = var.archive_node_count
  
  name        = "archive-node-${count.index + 1}"
  repository  = local.use_local_charts ? "" : local.mina_helm_repo
  chart       = local.use_local_charts ? "../../../../helm/archive-node" : "archive-node"
  version     = "0.4.6"
  namespace   = kubernetes_namespace.testnet_namespace.metadata[0].name
  values      = [
    yamlencode(local.archive_node_vars)
  ]

  wait = false
  timeout     = 600
  depends_on = [helm_release.seed]
}
