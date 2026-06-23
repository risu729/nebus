# **Architecture Design and Refinement: Automated Kubernetes on Oracle Cloud Infrastructure (Always Free Tier)**

The architectural deployment of a fully automated, GitOps-driven Kubernetes cluster within the strict confines of the Oracle Cloud Infrastructure (OCI) Always Free tier represents a highly complex engineering challenge. The integration of HashCorp Cloud Platform (HCP) Terraform via Workload Identity, the deployment of Talos Linux on ARM64 compute shapes, the implementation of shared-nothing storage topographies, and the execution of deep Layer 7 network security protocols require a meticulous orchestration of cloud-native primitives. The proposed architecture navigates the precarious balance between resource starvation and enterprise-grade resilience, utilizing modern Rust-based application alternatives and deeply integrated eBPF networking to maximize the utility of the hardware allocation. The ensuing analysis provides an exhaustive breakdown of the infrastructure mechanisms, evaluating the secondary and tertiary implications of each design decision within this highly constrained environment.

## **1\. Infrastructure Provisioning and Workload Identity Federation**

The foundational layer of the architecture dictates that infrastructure code is decoupled from manual execution and static credentialing, utilizing an automated pipeline driven by GitHub Actions and HashCorp Cloud Platform (HCP) Terraform. The shift away from long-lived API tokens fundamentally alters the threat model of the continuous integration and continuous deployment (CI/CD) pipeline.

### **Cryptographic Handshake and OIDC Mechanics**

The legacy paradigm of securely storing a long-lived API token within GitHub Secrets introduces a persistent vulnerability window; if the token is compromised, an attacker gains unbounded access to the infrastructure state.1 The transition to OpenID Connect (OIDC) relies on Workload Identity Federation to establish an ephemeral, cryptographically verifiable trust mechanism between GitHub Actions and HCP Terraform.2

The execution model operates as a purely Version Control System (VCS)-driven workflow. When a commit is pushed to the main branch, the GitHub Actions runner requests a JSON Web Token (JWT) from GitHub's OIDC provider. This token contains highly specific identity claims, including the repository name, the triggering event, the specific branch reference, and the repository owner.2 HCP Terraform is configured with a trust policy that explicitly defines the acceptable audience and verifies the cryptographic signature of the JWT against GitHub's published public keys.3 Upon successful verification of the claims, HCP Terraform issues a short-lived access token strictly scoped to the required workspace and the duration of the execution pipeline.4 This ensures that even if the ephemeral token is intercepted, its utility expires rapidly, and its scope is restricted, severely limiting the potential blast radius.

The pipeline is further hardened by enforcing static analysis and formatting prior to the infrastructure reconciliation phase. Tools such as tflint and terraform fmt are invoked via the mise runtime manager within the GitHub Actions runner.3 By gating the deployment behind these linters, the architecture guarantees that syntactical anomalies and suboptimal resource definitions are rejected before they can generate a Terraform plan, ensuring that the state file remains pristine and the declarative intent is strictly maintained.

### **Oracle Cloud Infrastructure Resource Constraints**

The OCI Always Free tier imposes rigid hardware limitations that dictate the overall topology of the Kubernetes cluster. The free allocation for ARM-based Ampere A1 compute provides a maximum of 4 OCPUs and 24 GB of RAM, equivalent to 3,000 OCPU hours and 18,000 GB hours per month.5 Additionally, the tenancy is granted a maximum of 200 GB of total block volume storage, which encompasses all boot volumes and attached data volumes.7

The architecture divides the compute allocation into three identical VM.Standard.A1.Flex instances, each provisioned with 1 OCPU and 8 GB of RAM.6 This highly symmetrical setup fulfills the fundamental requirement for etcd quorum and Kubernetes control plane high availability, which mandates an odd number of nodes to maintain database consensus during network partition events.

The storage mathematics within this configuration represent a critical bottleneck. The minimum permissible boot volume size for an OCI compute instance, regardless of the compute shape, is 47 GB.6 By utilizing the standard OCI default boot volume allocation of 50 GB per node, the three-node cluster consumes exactly 150 GB of the maximum 200 GB free tier allowance.7 This allocation leaves a theoretical remainder of 50 GB of block storage. However, carving out this remaining capacity into separate, highly available block volumes for distributed storage systems is economically unfeasible and technically insufficient for enterprise-grade data redundancy. Consequently, the architecture correctly abandons dedicated block volumes, absorbing the storage requirement directly into the localized 50 GB boot volumes via a Local Path Provisioner to remain strictly within the billing threshold.9

| Resource Type | Total OCI Free Tier Limit | Allocation Per Node | Total Consumed | Remaining Capacity |
| :---- | :---- | :---- | :---- | :---- |
| Compute (ARM A1) | 4 OCPUs | 1 OCPU | 3 OCPUs | 1 OCPU |
| Memory (ARM A1) | 24 GB RAM | 8 GB RAM | 24 GB RAM | 0 GB RAM |
| Block Volume Storage | 200 GB | 50 GB (Boot Volume) | 150 GB | 50 GB |

## **2\. Operating System Topography: Talos Linux on ARM64**

The selection of Talos Linux as the underlying operating system signifies a departure from traditional, mutable Linux distributions in favor of a specialized, API-driven immutable infrastructure model. Talos strips away SSH, shell access, systemd, and traditional package managers, reducing the attack surface to a singular, mutually authenticated gRPC API.10

### **Custom Image Bootstrapping via Image Factory**

Because Oracle Cloud Infrastructure does not natively distribute official Talos Linux images, the deployment requires a custom initialization sequence known as the "Bring Your Own Image" (BYOI) methodology. The architecture requires generating a specialized artifact via the Talos Image Factory.12 The Image Factory compiles a customized kernel and initramfs based on a specific schematic ID, integrating necessary system extensions directly into the boot asset.13

For the VM.Standard.A1.Flex shape, an aarch64 raw disk image is generated and subsequently converted into a QCOW2 virtual machine image format utilizing QEMU utilities.12 This disk image must be packaged alongside an image\_metadata.json file, which is critical for instructing the OCI hypervisor on how to interface with the operating system. The metadata explicitly defines the firmware as UEFI\_64 and specifies that the network interfaces, boot volumes, and remote data volumes must operate in PARAVIRTUALIZED mode.12

This metadata, bundled with the QCOW2 file into an .oci archive, is uploaded to an OCI Object Storage bucket and imported as a custom computing image.12 When HCP Terraform issues the command to instantiate the compute shapes, it references the Oracle Cloud Identifier (OCID) of this custom image, allowing the instances to boot directly into the Talos environment.

### **Cluster Initialization Sequence**

The provisioning sequence utilizes OCI's user-data injection to supply the cryptographic machine configurations directly to the nodes during their initial boot phase. Prior to instantiation, the talosctl gen config command is executed to generate the overarching cluster secrets, the controlplane.yaml, the worker.yaml, and the talosconfig client file.12

Because all three nodes must participate in the scheduling of workloads due to the severe hardware constraints (specifically, the lack of dedicated worker nodes to conserve OCPUs), the controlplane.yaml must be aggressively modified. The default Kubernetes behavior applies a node-role.kubernetes.io/control-plane:NoSchedule taint to control plane nodes to isolate system components from user workloads. In this architecture, this taint is removed, allowing end-user application pods to schedule alongside the Kubernetes API server, the scheduler, and the controller manager.14 Once the initial node receives its configuration and achieves a ready state, the talosctl bootstrap command is executed to initialize the etcd database, finalizing the consensus ring and establishing the functional control plane.10

## **3\. Data Persistence and Replication Mechanisms**

The physical limitations of the OCI Free Tier dictate the fundamental storage architecture of the cluster. Kubernetes workloads heavily rely on persistent volumes to maintain state across pod evictions and node reboots. In enterprise environments, this is typically handled by distributed, software-defined storage solutions such as Ceph (via Rook) or Longhorn.

### **The Economics of Local Storage**

The deployment of distributed block storage systems introduces severe computational overhead. Systems like Rook-Ceph require gigabytes of RAM purely to maintain the storage monitoring daemons and Object Storage Daemons (OSDs), while heavily taxing the CPU to compute cryptographic hashes and maintain data replication across the network. Given that each node in this architecture is constrained to a single ARM OCPU and 8 GB of RAM, running a distributed storage layer would trigger aggressive out-of-memory (OOM) evictions and completely starve the application layer of compute resources.15 Furthermore, the tenancy's hard limit of 200 GB for total block volume storage means that allocating dedicated volumes for a Ceph cluster is mathematically impossible once the 150 GB required for the three boot volumes is subtracted.7

The architecture resolves this by employing a Local Path Provisioner (LPP). The LPP acts as a dynamic volume provisioner that translates Kubernetes Persistent Volume Claims (PVCs) directly into host-path directories on the underlying boot volume.15 This entirely eliminates the CPU and RAM overhead associated with distributed storage, offering near-native NVMe disk I/O performance directly from the OCI infrastructure.

However, Local Path Provisioning introduces a critical vulnerability: data gravity. Data is pinned to the specific physical node where the pod was initially scheduled. If Node A experiences a hardware failure or undergoes a reboot, the data residing on its host-path is completely inaccessible to the rest of the cluster. If the Kubernetes scheduler attempts to instantiate the orphaned pod on Node B, the pod will fail to mount the volume, resulting in an indefinite Pending state.

### **Application-Level Replication Mechanics**

To mitigate the fragility of local storage, data redundancy must be escalated from the infrastructure layer (storage) up to the application layer (database operators). The architecture relies on specialized Kubernetes Operators to maintain quorum and replicate state across the three nodes independently of the storage provider. Because LPP is node-local, replication is mandatory; if a pod reschedules from Node A to Node B, it must find its data already synced and waiting on the local disk.

**PostgreSQL via CloudNativePG (CNPG):** The architecture utilizes the CloudNativePG operator to manage relational database states. CNPG explicitly advocates for a shared-nothing architecture, recommending the use of locally attached volumes to maximize transaction throughput and minimize network latency.16 When a three-node CNPG cluster is instantiated, the operator schedules one primary instance and two hot standby replicas, distributing them across the three distinct physical nodes via pod anti-affinity rules.16

Data synchronization is handled via native PostgreSQL streaming replication. When a write transaction occurs on the primary pod, the data is written to the local host-path volume and simultaneously streamed over the network overlay to the standby pods, which write the data to their respective local volumes.16 If the primary node undergoes a catastrophic failure, the CNPG operator immediately detects the loss of the primary HA slot, initiates an automated failover sequence, and promotes the most synchronized standby pod to the primary role.19 The application endpoints are seamlessly repointed via Kubernetes service routing, ensuring uninterrupted database availability.

**Redis and MongoDB High Availability:** Similarly, caching and document storage are protected via their respective operators. The OT-Container-Kit Redis Operator is deployed to instantiate a highly available Redis cluster configured in Sentinel mode with 3 replicas.20 Sentinel daemon pods continuously monitor the primary Redis shard. If a node failure occurs, the remaining Sentinels execute a leader election and promote a replica to primary. For caching layers, this replication is vital to prevent "thundering herd" scenarios; if a Redis cache node restarts without replication, a massive influx of cache misses can suddenly overwhelm backend databases, causing cascading system failures. For NoSQL requirements, the MongoDB Community Operator provisions a highly available 3-node ReplicaSet.22 The operator ensures that MongoDB's internal Oplog (operations log) synchronizes data modifications across the LPP directories on all three instances, ensuring applications like the Matrix homeserver remain completely consistent across node reboots.

| Application Layer | Operator Used | HA Strategy | Replication Target | Failure Mitigation |
| :---- | :---- | :---- | :---- | :---- |
| PostgreSQL | CloudNativePG | 3-node Native Streaming | Local Path Provisioner | Automated promotion of hot standby |
| Redis | OT-Container-Kit | 3-node Sentinel Mode | Local Path Provisioner | Prevention of thundering herd cache misses |
| MongoDB | MongoDB Community | 3-node ReplicaSet | Local Path Provisioner | Oplog sync prevents data loss on reboot |

## **4\. Connectivity, Ingress, and Edge Security Datapaths**

Exposing a Kubernetes cluster to the public internet introduces profound security liabilities, particularly for an architecture constrained by the compute limits of the free tier, which cannot absorb the volumetric impact of distributed denial-of-service (DDoS) attacks. The architecture routes all ingress HTTP/HTTPS traffic through the Cloudflare proxy network, utilizing Cloudflare's massive global edge to absorb malicious volumetric traffic and filter malignant payloads before they reach the OCI network perimeter.

### **L3/L4 Infrastructure Defense**

At the infrastructure layer, the OCI Virtual Cloud Network (VCN) relies on Network Security Groups (NSGs) to provide stateful firewalling around the compute instances. The NSG is configured to drop all external internet traffic, explicitly permitting ingress on ports 80 and 443 solely from the published Autonomous System Numbers (ASNs) and IP ranges owned by Cloudflare. This ensures that an attacker cannot bypass the Cloudflare Web Application Firewall (WAF) by directly querying the "Raw IP" addresses assigned to the OCI load balancer.

However, layer 3 and layer 4 IP allowlisting is inherently susceptible to circumvention. If an attacker identifies the origin IP address of the OCI Load Balancer, they can configure a custom DNS resolution on their local machine to route malicious requests through their own Cloudflare account. Because the traffic physically originates from a Cloudflare server, the OCI NSG evaluates the traffic as trusted and permits it through the firewall, successfully bypassing the defensive perimeter.

### **L7 Cryptographic Header Validation via eBPF and Envoy**

To neutralize the origin-spoofing threat, the architecture implements deep Layer 7 cryptographic validation using Cilium and Envoy. Cloudflare Transform Rules are configured at the edge to inject a highly entropic, shared secret into the HTTP request headers, designated as X-Origin-Auth.24

The cluster utilizes Cilium as its Container Network Interface (CNI), which relies heavily on extended Berkeley Packet Filter (eBPF) technologies to manipulate network packets directly within the Linux kernel, bypassing the traditional iptables networking stack.24 For Layer 7 ingress operations, Cilium integrates an embedded Envoy proxy. When traffic arrives at the node via the OCI Load Balancer, eBPF hooks intercept the packets and transparently redirect them to the Envoy process via the TPROXY kernel facility.24

The validation mechanism leverages a CiliumClusterwideEnvoyConfig Custom Resource Definition (CRD), which allows cluster administrators to inject advanced Lua scripts directly into the Envoy filter chain without modifying the underlying container images.26 The custom Envoy configuration executes an embedded Lua script during the request decoding phase. The script interrogates the incoming HTTP request, specifically invoking request\_handle:headers():get("X-Origin-Auth").27 If the header is absent, or if the cryptographic value does not perfectly match the localized cluster secret, the Lua filter immediately intercepts the traffic flow and issues a hard 403 Forbidden response back to the client.27

This dual-layered approach guarantees that traffic must physically originate from Cloudflare's network (verified at Layer 4 by OCI NSGs) and must specifically route through the authorized Cloudflare tenant account (verified at Layer 7 by the Envoy Lua filter), establishing an uncompromising zero-trust perimeter at the ingress boundary.

### **Management Plane Access via Cloudflare Tunnels**

The Talos Linux management architecture relies on a gRPC API operating over TCP port 50000, secured via mutual TLS (mTLS).29 While mTLS provides robust cryptographic authentication, exposing port 50000 directly to the internet via OCI load balancers exposes the API server to network probing and potential zero-day vulnerabilities in the cryptographic libraries.

To achieve complete invisibility of the management plane, the architecture leverages Cloudflare Tunnels, establishing an outbound-only TCP connection from the Talos nodes to the Cloudflare edge, thereby requiring zero open inbound ports on the OCI firewall. Because Talos is an immutable operating system that lacks a traditional package manager, installing the cloudflared daemon requires the use of a Talos System Extension.31

The extension is compiled into the boot asset via the Image Factory, mounting the cloudflared binary into the read-only root filesystem.32 An ExtensionServiceConfig YAML document is injected into /usr/local/etc/containers/, instructing the Talos initialization system to launch the daemon as a privileged container during the early boot phase.31 The configuration specifies the tunnel UUID and maps the ingress traffic to localhost:50000 over a TCP proxy.33

For cluster administrators requiring operational access from a CI/CD runner or a local workstation, the client executes cloudflared access tcp \--hostname talos.example.com \--url localhost:50000.34 This command authenticates the user against Cloudflare Zero Trust policies and opens a secure local socket. The administrator's talosconfig is subsequently configured to point to 127.0.0.1:50000, seamlessly routing the gRPC commands through the encrypted tunnel directly to the node's API server without ever traversing the public internet.34

## **5\. Layered GitOps Architecture and Bootstrap Sequence**

The operational state of the cluster is maintained strictly through declarative GitOps methodologies. However, relying on a singular GitOps controller to manage both foundational cluster infrastructure and volatile end-user applications frequently leads to circular dependencies, repository bloat, and fragile bootstrap sequences. To establish robust fault domains, the architecture implements a layered GitOps model, utilizing both Flux CD and Argo CD in a highly orchestrated handoff pattern.35

### **Layer 0: Foundational Infrastructure via Flux CD**

Flux CD operates as the "Base Layer" (Layer 0\) orchestrator. Its primary mandate is to interact directly with the Kubernetes API to bootstrap the core cluster infrastructure immediately after the Talos nodes initialize. The lightweight nature of Flux's decentralized controllers (such as the source-controller and kustomize-controller) makes it highly efficient for bootstrapping constrained edge environments.35

Upon installation, Flux CD synchronizes against an infrastructure-specific Git repository. It is responsible for sequentially applying critical primitives that the cluster requires to function:

1. **Cilium CNI:** Establishing the eBPF network overlay, routing capabilities, and the Envoy proxy configurations for L3/L4/L7 security and Ingress.  
2. **OCI Cloud Controller Manager (CCM):** Enabling the cluster to interface with the Oracle APIs to request IP allocations and dynamically provision load balancers.  
3. **Sealed Secrets:** Deploying the decryption controller. During the initial GitHub Actions bootstrap sequence, the private decryption key is injected into the cluster from GitHub Secrets. This allows all subsequent GitOps deployments to safely commit encrypted SealedSecret resources into public repositories, knowing only the cluster possesses the key to decrypt them into native Kubernetes Secret objects.

Crucially, the final act of the Flux CD reconciliation loop is the deployment of the Argo CD manifests.37 Once Argo CD achieves a ready state, Flux CD's primary objective is concluded, and responsibility for the application layer is formally handed off.

### **Layer 1: Application Lifecycle via Argo CD**

Argo CD operates as the "App Layer" (Layer 1\) orchestrator. While Flux CD excels at headless infrastructure synchronization, Argo CD provides a superior abstraction model for application delivery, featuring robust multi-tenant capabilities, health inspection logic, and a centralized orchestrator for deploying end-user applications.35

Argo CD manages all end-user applications strictly through Helm charts. Rather than maintaining massive directories of manual, raw YAML manifests for every application, Argo CD utilizes its internal repo-server to dynamically render Helm charts sourced directly from upstream repositories.39 The deployment utilizes the ApplicationSet pattern, which dynamically generates and manages Argo Application custom resources, facilitating massive scalability and clean repository structures.40

To maintain the absolute integrity of the GitOps paradigm, the Argo CD deployment is aggressively hardened via GUI restrictions. All interactive Web UI editing features and manual synchronization buttons are programmatically disabled.40 The UI serves exclusively as an observability pane; any deviation from the Git repository state is immediately overwritten by Argo's automated self-healing mechanisms, guaranteeing that the repository remains the absolute single source of truth for the entire application stack.

## **6\. OCI Identity and Access Management (IAM) Policies**

Authenticating the Kubernetes infrastructure controllers against the OCI APIs requires precise Identity and Access Management (IAM) configurations. Hardcoding long-lived OCI user credentials or API signing keys into Kubernetes secrets introduces significant security liabilities. Instead, the architecture utilizes OCI Instance Principals, allowing the Talos compute instances themselves to act as authorized actors.41

The initial phase requires defining a Dynamic Group within the OCI IAM console. The matching rule identifies all instances belonging to the cluster by specifying the compartment OCID or utilizing tagging mechanisms. For example, a dynamic group named K8sGroup is populated using the logic instance.compartment.id \= '\<compartment-ocid\>'.42

Once the dynamic group is established, granular policy statements are authored to grant least-privilege access to the required OCI resources:

* **Cloud Controller Manager (CCM) Policy:** The OCI CCM runs within the cluster to automatically provision OCI Network Load Balancers when a Kubernetes service of type LoadBalancer is created.43 The CCM requires specific network management permissions applied directly to the dynamic group: Allow dynamic-group K8sGroup to manage load-balancers in compartment \<compartment\_name\>.45  
* **Object Storage Backup Policy:** To allow the database operators and CronJobs to stream backup data to off-site buckets, storage permissions are scoped strictly to the target bucket, preventing the instances from manipulating other storage assets in the tenancy: Allow dynamic-group K8sGroup to manage objects in compartment \<compartment\_name\> where target.bucket.name='k8s-backups'.47

## **7\. The "Real Apps" Stack and ARM64 Economics**

The viability of this architecture hinges entirely on the ability of the application layer to operate within the severe memory limits of the ARM A1 compute shapes. Legacy, monolithic applications designed for extensive horizontal scaling in cloud environments will instantly overwhelm the 8 GB per-node memory limit. Consequently, the application stack is heavily biased toward highly optimized, compiled languages, specifically Rust and Go. Furthermore, all applications utilize OCI Object Storage for heavy media and asset storage to keep the local LPP boot volumes lean.

### **Matrix Homeserver: The Shift to Tuwunel**

The implementation of a federated Matrix communication server illustrates the necessity of resource optimization. The reference Matrix homeserver, Synapse, is written in Python. In federated environments, particularly when joining large, globally distributed rooms (e.g., \#matrix:matrix.org), the Python Global Interpreter Lock (GIL) and continuous garbage collection routines cause severe memory bloat. Synapse deployments regularly consume multiple gigabytes of RAM merely to parse the cryptographic state resolution algorithms during room joins, frequently triggering OOM kills on memory-constrained hardware.49

To circumvent this, the architecture deploys **Tuwunel**, an enterprise-grade Matrix homeserver written entirely in Rust.51 As a high-performance successor to the Conduwuit project, Tuwunel utilizes a highly tuned embedded database optimized for concurrent read/write operations.52 The memory safety and zero-cost abstractions provided by the Rust compiler allow Tuwunel to process complex Matrix Federation state resolutions natively, without the overhead of an interpreted runtime.54

Benchmarking indicates that Tuwunel can operate a fully federated instance, maintaining connections to massive external communities, while consuming a fraction of the RAM required by Synapse (often maintaining a footprint well under 500 MB) and utilizing nominal CPU cycles.52 This drastic reduction in overhead guarantees that the Matrix communication layer can reside safely alongside the PostgreSQL CNPG database without destabilizing the node.

### **Optimization of Auxiliary Workloads**

The aggressive optimization strategy is replicated across the remaining application stack:

* **Vaultwarden:** Instead of deploying the official, resource-heavy Bitwarden server (which requires extensive MS SQL and.NET core containers), the architecture utilizes Vaultwarden. This alternative is a lightweight, Rust-based implementation of the Bitwarden API. It interfaces directly with the CNPG PostgreSQL cluster for persistence and backs up the vault directly to Object Storage, while utilizing mere megabytes of memory, providing enterprise-grade cryptographic vault management with a microscopic hardware footprint.56  
* **Docmost:** Operating as the primary documentation and collaborative wiki engine (replacing heavier Java-based alternatives like Confluence), Docmost relies on Node.js, Redis for session caching, and PostgreSQL for relational data.58 Because Docmost facilitates the upload of rich media and file attachments, storing these binaries within the Local Path Provisioner would rapidly exhaust the localized 50 GB boot volumes. To preserve disk capacity, the Docmost application configuration leverages environmental variables (STORAGE\_DRIVER=s3) to offload all heavy binary assets directly to OCI Object Storage via the Amazon S3 Compatibility API, ensuring the local Kubernetes volumes remain strictly reserved for database persistence.58

| Application | Primary Database | Primary Caching | Architectural Notes |
| :---- | :---- | :---- | :---- |
| **Matrix (Tuwunel)** | PostgreSQL (CNPG) | In-Memory (Rust) | Rust-based homeserver. Replaces Python-based Synapse to prevent RAM bloat during federation state resolution. |
| **Vaultwarden** | PostgreSQL (CNPG) | N/A | Bitwarden-compatible Rust implementation. Backs up encrypted vault data directly to Object Storage. |
| **Docmost** | PostgreSQL (CNPG) | Redis (OT Operator) | Documentation engine. Uses S3 Compatibility API to offload media/assets from the LPP boot volumes. |

## **8\. LPP Data Risk and Backup Strategy**

While application-level 3-way replication serves as the primary safety net against individual node failures, it does not protect against systemic cluster failures, accidental namespace deletions, or unrecoverable data corruption. Because the underlying Local Path Provisioner storage is inherently ephemeral to the lifespan of the host, a robust, off-site disaster recovery strategy is paramount.

### **Automated Snapshots to OCI Object Storage**

The backup strategy relies heavily on extracting data from the LPP volumes and transporting it to OCI Object Storage. CloudNativePG facilitates this via continuous physical backups and Write-Ahead Log (WAL) archiving.59 Instead of utilizing standard logical dumps (e.g., pg\_dump), CNPG natively integrates the Barman Cloud toolkit to orchestrate hot backups without requiring database downtime.59

Because OCI Object Storage supports the Amazon S3 Compatibility API, the CNPG cluster configuration utilizes the s3Credentials block and defines the destinationPath as s3://k8s-backups/.61 The endpointURL is configured to target the specific OCI namespace and region API gateway.63

A critical nuance of interfacing with OCI Object Storage via S3-compatible SDKs (such as the boto3 libraries utilized by Barman) is the handling of checksums. OCI frequently rejects S3 API requests that lack explicit content-length and payload hashes. To rectify this, the backup triggers must inject specific environmental variables—AWS\_REQUEST\_CHECKSUM\_CALCULATION=when\_required and AWS\_RESPONSE\_CHECKSUM\_VALIDATION=when\_required—to ensure that the cryptographic checksums are appended to the HTTP payload during the Object Storage transmission.64

### **Trigger Mechanisms and Recovery Sequence**

The backup operations are initiated by two distinct mechanisms. For relational databases, the triggers are managed natively by the DB Operator CRDs (e.g., CNPG handles its own scheduled WAL archiving and base backups). For flat-file application state or internal SQLite databases, standard Kubernetes CronJobs are deployed to execute daily data dumps and stream the resulting archives to the S3 endpoint.

In the event of total cluster annihilation, the recovery sequence is entirely deterministic and heavily leverages the Layered GitOps architecture:

1. HCP Terraform reprovisions the bare Talos nodes and custom images.  
2. Flux CD bootstraps the cluster, installs the Cilium CNI, and re-injects the kubeseal private keys from GitHub Secrets, allowing the cluster to natively decrypt its own passwords.  
3. Argo CD syncs from the repository, re-deploying the database operators (CNPG, Redis, MongoDB).  
4. Instead of a standard database initialization, a manual Restore CRD is applied to the cluster. This instructs the CNPG operator to connect to the OCI Object Storage bucket, pull the latest base tarball, and replay the archived WAL files, restoring the database to its exact pre-disaster state.59

## **9\. Observability Architecture (Planned)**

A comprehensive observability stack is crucial for monitoring cluster health, tracking network latency, and diagnosing application bottlenecks. However, in the current deployment phase, the observability stack remains intentionally inactive to preserve the strict 8 GB per-node free-tier RAM limits.6

Traditional observability agents, such as Prometheus for metrics scraping and Promtail for log forwarding, are notoriously resource-intensive. Running a full Prometheus server within the cluster would require maintaining massive time-series databases in memory, which would quickly exhaust the remaining RAM and trigger OOM evictions for critical applications like the Matrix homeserver.65

### **The Grafana Alloy and S3-Backend Strategy**

When the observability stack is eventually activated, the architecture plans to utilize a highly optimized pipeline: **Grafana Alloy \-\> Loki/Mimir \-\> OCI Object Storage.**

Grafana Alloy will be deployed as the unified OpenTelemetry collector, replacing standalone instances of Promtail and Prometheus agents. Alloy features a significantly reduced memory footprint and acts as a single pipeline for metrics, logs, and traces.

Instead of storing the aggregated logs and metrics on the localized LPP boot volumes—which would rapidly exhaust the 50 GB disk quota—the data will be forwarded to Grafana Loki (for logs) and Grafana Mimir (for metrics). Both Loki and Mimir are specifically designed to decouple data ingestion from data storage. They will be configured to utilize OCI Object Storage via the S3 Compatibility API as their primary backing store. This architecture ensures that massive volumes of index and chunk data are offloaded to cheap, virtually limitless cloud storage, preventing data gravity from overwhelming the localized Kubernetes nodes while maintaining full query capabilities.

## **Conclusion**

The automated Kubernetes architecture delineated above succeeds by rigorously adapting modern cloud-native principles to the inflexible constraints of the Oracle Cloud Infrastructure Always Free tier. By bypassing legacy operational models, the deployment leverages HashCorp Workload Identity for zero-trust OIDC provisioning, and harnesses Talos Linux to enforce immutability at the OS level.

The strategic reliance on Local Path Provisioning bypasses the compute and capacity penalties of distributed block storage, while the integration of operators like CloudNativePG ensures high availability is maintained mathematically through application-level replication across the three distinct nodes. Edge security is achieved not through perimeter firewalls, but via cryptographic header validation injected by eBPF-powered Envoy filters, ensuring absolute origin verification from Cloudflare. Finally, the layered deployment of Flux CD and Argo CD establishes a resilient, self-healing GitOps continuum, while the selection of heavily optimized, Rust-based applications like Tuwunel and Vaultwarden ensures the compute envelope is respected. The resulting infrastructure is highly available, cryptographically secure, fully automated, and operates entirely free of recurring computational costs.

#### **Works cited**

1. Automate Terraform with GitHub Actions \- HashCorp Developer, accessed on February 24, 2026, [https://developer.hashicorp.com/terraform/tutorials/automation/github-actions](https://developer.hashicorp.com/terraform/tutorials/automation/github-actions)  
2. Integrating OIDC with Github Action to Manage Terraform Deployment on AWS \- Firefly AI, accessed on February 24, 2026, [https://www.firefly.ai/academy/integrating-oidc-with-github-action-to-manage-terraform-deployment-on-aws](https://www.firefly.ai/academy/integrating-oidc-with-github-action-to-manage-terraform-deployment-on-aws)  
3. Authentication with GitHub OIDC | Guides | deploymenttheory/microsoft365 | Terraform, accessed on February 24, 2026, [https://registry.terraform.io/providers/deploymenttheory/microsoft365/latest/docs/guides/oidc\_github](https://registry.terraform.io/providers/deploymenttheory/microsoft365/latest/docs/guides/oidc_github)  
4. Using Terraform to connect GitHub Actions and AWS with OIDC | by Thiago Salvatore, accessed on February 24, 2026, [https://medium.com/@thiagosalvatore/using-terraform-to-connect-github-actions-and-aws-with-oidc-0e3d27f00123](https://medium.com/@thiagosalvatore/using-terraform-to-connect-github-actions-and-aws-with-oidc-0e3d27f00123)  
5. Oracle Cloud Free Tier, accessed on February 24, 2026, [https://www.oracle.com/cloud/free/](https://www.oracle.com/cloud/free/)  
6. Always Free Resources \- Oracle Help Center, accessed on February 24, 2026, [https://docs.oracle.com/iaas/Content/FreeTier/freetier\_topic-Always\_Free\_Resources.htm](https://docs.oracle.com/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)  
7. A Question About Always Free Limits : r/oraclecloud \- Reddit, accessed on February 24, 2026, [https://www.reddit.com/r/oraclecloud/comments/1f8pqsm/a\_question\_about\_always\_free\_limits/](https://www.reddit.com/r/oraclecloud/comments/1f8pqsm/a_question_about_always_free_limits/)  
8. oracle-cloud-free-tier-guide \- GitHub Gist, accessed on February 24, 2026, [https://gist.github.com/rssnyder/51e3cfedd730e7dd5f4a816143b25dbd](https://gist.github.com/rssnyder/51e3cfedd730e7dd5f4a816143b25dbd)  
9. OCI Price List \- Oracle, accessed on February 24, 2026, [https://www.oracle.com/cloud/price-list/](https://www.oracle.com/cloud/price-list/)  
10. A Simple Way to Install Talos Linux on Any Machine, with Any Provider, accessed on February 24, 2026, [https://www.linux.com/thelinuxfoundation/a-simple-way-to-install-talos-linux-on-any-machine-with-any-provider/](https://www.linux.com/thelinuxfoundation/a-simple-way-to-install-talos-linux-on-any-machine-with-any-provider/)  
11. Talos Linux \- The Kubernetes Operating System, accessed on February 24, 2026, [https://www.talos.dev/](https://www.talos.dev/)  
12. Oracle \- Sidero Documentation \- What is Talos Linux?, accessed on February 24, 2026, [https://docs.siderolabs.com/talos/v1.8/platform-specific-installations/cloud-platforms/oracle](https://docs.siderolabs.com/talos/v1.8/platform-specific-installations/cloud-platforms/oracle)  
13. Image Factory \- Sidero Documentation \- What is Talos Linux?, accessed on February 24, 2026, [https://docs.siderolabs.com/talos/v1.9/learn-more/image-factory](https://docs.siderolabs.com/talos/v1.9/learn-more/image-factory)  
14. How I Setup Talos Linux. My journey to building a secure… | by Pedro Chang | Medium, accessed on February 24, 2026, [https://medium.com/@pedrotychang/how-i-setup-talos-linux-bc2832ec87cc](https://medium.com/@pedrotychang/how-i-setup-talos-linux-bc2832ec87cc)  
15. Which Storage Solution for CNPG \- kubernetes \- Reddit, accessed on February 24, 2026, [https://www.reddit.com/r/kubernetes/comments/1g8v4bg/which\_storage\_solution\_for\_cnpg/](https://www.reddit.com/r/kubernetes/comments/1g8v4bg/which_storage_solution_for_cnpg/)  
16. Architecture \- CloudNativePG, accessed on February 24, 2026, [https://cloudnative-pg.io/documentation/1.18/architecture/](https://cloudnative-pg.io/documentation/1.18/architecture/)  
17. Architecture | CloudNativePG, accessed on February 24, 2026, [https://cloudnative-pg.io/docs/devel/architecture/](https://cloudnative-pg.io/docs/devel/architecture/)  
18. Helm Reference — Cilium 1.19.1 documentation, accessed on February 24, 2026, [https://docs.cilium.io/en/stable/helm-reference.html](https://docs.cilium.io/en/stable/helm-reference.html)  
19. Replication \- CloudNativePG, accessed on February 24, 2026, [https://cloudnative-pg.io/documentation/1.18/replication/](https://cloudnative-pg.io/documentation/1.18/replication/)  
20. OT-CONTAINER-KIT/redis-operator: A golang based redis operator that will make/oversee Redis standalone/cluster/replication/sentinel mode setup on top of the Kubernetes. \- GitHub, accessed on February 24, 2026, [https://github.com/OT-CONTAINER-KIT/redis-operator](https://github.com/OT-CONTAINER-KIT/redis-operator)  
21. Redis Operator : spotathome vs ot-container-kit : r/kubernetes \- Reddit, accessed on February 24, 2026, [https://www.reddit.com/r/kubernetes/comments/192d8yn/redis\_operator\_spotathome\_vs\_otcontainerkit/](https://www.reddit.com/r/kubernetes/comments/192d8yn/redis_operator_spotathome_vs_otcontainerkit/)  
22. Install MongoDB Community Kubernetes Operator, accessed on February 24, 2026, [https://www.mongodb.com/try/download/community-kubernetes-operator](https://www.mongodb.com/try/download/community-kubernetes-operator)  
23. MongoDB Community Kubernetes Operator on ARM64 | by Arko Basu \- Medium, accessed on February 24, 2026, [https://medium.com/@arko.basu09/mongodb-community-kubernetes-operator-on-arm64-8c3b6ddf9c35](https://medium.com/@arko.basu09/mongodb-community-kubernetes-operator-on-arm64-8c3b6ddf9c35)  
24. Kubernetes Ingress Support — Cilium 1.19.1 documentation, accessed on February 24, 2026, [https://docs.cilium.io/en/stable/network/servicemesh/ingress.html](https://docs.cilium.io/en/stable/network/servicemesh/ingress.html)  
25. Adding header with Cilium Ingress/Gateway API based on client IP : r/kubernetes \- Reddit, accessed on February 24, 2026, [https://www.reddit.com/r/kubernetes/comments/1hx0xzy/adding\_header\_with\_cilium\_ingressgateway\_api/](https://www.reddit.com/r/kubernetes/comments/1hx0xzy/adding_header_with_cilium_ingressgateway_api/)  
26. How to Apply Custom Envoy Configurations in a Cilium Setup (with Rate Limiting Example), accessed on February 24, 2026, [https://medium.com/@samyak-devops/how-to-apply-custom-envoy-configurations-in-a-cilium-setup-with-rate-limiting-example-5301972460f2](https://medium.com/@samyak-devops/how-to-apply-custom-envoy-configurations-in-a-cilium-setup-with-rate-limiting-example-5301972460f2)  
27. How to Build Advanced Istio EnvoyFilters \- OneUptime, accessed on February 24, 2026, [https://oneuptime.com/blog/post/2026-01-30-istio-envoyfilter-advanced/view](https://oneuptime.com/blog/post/2026-01-30-istio-envoyfilter-advanced/view)  
28. Istio Envoyfilter with inline Lua Script for external\_authz always returns 403 \#21637 \- GitHub, accessed on February 24, 2026, [https://github.com/istio/istio/issues/21637](https://github.com/istio/istio/issues/21637)  
29. Production Clusters \- Sidero Documentation \- What is Talos Linux?, accessed on February 24, 2026, [https://docs.siderolabs.com/talos/v1.7/getting-started/prodnotes](https://docs.siderolabs.com/talos/v1.7/getting-started/prodnotes)  
30. control ports on the internet · siderolabs talos · Discussion \#10745 \- GitHub, accessed on February 24, 2026, [https://github.com/siderolabs/talos/discussions/10745](https://github.com/siderolabs/talos/discussions/10745)  
31. Extension Services \- Sidero Documentation \- What is Talos Linux?, accessed on February 24, 2026, [https://docs.siderolabs.com/talos/v1.8/build-and-extend-talos/custom-images-and-development/extension-services](https://docs.siderolabs.com/talos/v1.8/build-and-extend-talos/custom-images-and-development/extension-services)  
32. Package cloudflared \- GitHub, accessed on February 24, 2026, [https://github.com/siderolabs/extensions/pkgs/container/cloudflared](https://github.com/siderolabs/extensions/pkgs/container/cloudflared)  
33. Cloudflared on Ubuntu for ssh \- breadNET Documentation, accessed on February 24, 2026, [https://documentation.breadnet.co.uk/kb/cloudflared/cloudflared-on-ubuntu-for-ssh/](https://documentation.breadnet.co.uk/kb/cloudflared/cloudflared-on-ubuntu-for-ssh/)  
34. gRPC · Cloudflare One docs, accessed on February 24, 2026, [https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/grpc/](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/grpc/)  
35. Argo CD vs Flux: Which GitOps Tool is Right for You? \- Plural, accessed on February 24, 2026, [https://www.plural.sh/blog/argo-cd-vs-flux/](https://www.plural.sh/blog/argo-cd-vs-flux/)  
36. FluxCD Multi-cluster Architecture | by Stefan Prodan \- Medium, accessed on February 24, 2026, [https://medium.com/@stefanprodan/fluxcd-multi-cluster-architecture-e426fb2bca0f](https://medium.com/@stefanprodan/fluxcd-multi-cluster-architecture-e426fb2bca0f)  
37. How to Migrate from Flux to Argo CD | Live Demo \- YouTube, accessed on February 24, 2026, [https://www.youtube.com/watch?v=iCjCzYAwnOk](https://www.youtube.com/watch?v=iCjCzYAwnOk)  
38. GitOps on Kubernetes: Deciding Between Argo CD and Flux \- The New Stack, accessed on February 24, 2026, [https://thenewstack.io/gitops-on-kubernetes-deciding-between-argo-cd-and-flux/](https://thenewstack.io/gitops-on-kubernetes-deciding-between-argo-cd-and-flux/)  
39. Argo CD or Flux CD \- What is the most used CI/CD Tool : r/kubernetes \- Reddit, accessed on February 24, 2026, [https://www.reddit.com/r/kubernetes/comments/1937tty/argo\_cd\_or\_flux\_cd\_what\_is\_the\_most\_used\_cicd\_tool/](https://www.reddit.com/r/kubernetes/comments/1937tty/argo_cd_or_flux_cd_what_is_the_most_used_cicd_tool/)  
40. Cluster Bootstrapping \- Argo CD \- Declarative GitOps CD for Kubernetes \- Read the Docs, accessed on February 24, 2026, [https://argo-cd.readthedocs.io/en/latest/operator-manual/cluster-bootstrapping/](https://argo-cd.readthedocs.io/en/latest/operator-manual/cluster-bootstrapping/)  
41. Managing Dynamic Groups \- Oracle Help Center, accessed on February 24, 2026, [https://docs.oracle.com/en-us/iaas/Content/Identity/Tasks/managingdynamicgroups.htm](https://docs.oracle.com/en-us/iaas/Content/Identity/Tasks/managingdynamicgroups.htm)  
42. 5.2.1 Log Monitoring Using OCI Logging \- TheKoguryo's Tech Blog, accessed on February 24, 2026, [https://thekoguryo.github.io/en/oracle-cloudnative/oci-services/logging/1.oci-logging/](https://thekoguryo.github.io/en/oracle-cloudnative/oci-services/logging/1.oci-logging/)  
43. Use OCI Cloud Controller Manager on Oracle Cloud Native Environment, accessed on February 24, 2026, [https://docs.oracle.com/en/learn/ocne-loadbalancer](https://docs.oracle.com/en/learn/ocne-loadbalancer)  
44. oracle/oci-cloud-controller-manager \- GitHub, accessed on February 24, 2026, [https://github.com/oracle/oci-cloud-controller-manager](https://github.com/oracle/oci-cloud-controller-manager)  
45. Policies for Load Balancers \- Oracle Help Center, accessed on February 24, 2026, [https://docs.oracle.com/en-us/iaas/disaster-recovery/doc/load-balancer-policies.html](https://docs.oracle.com/en-us/iaas/disaster-recovery/doc/load-balancer-policies.html)  
46. Kubeception with CAPOCI — Cluster API for OCI — Part 1 | by Ali Mukadam \- Medium, accessed on February 24, 2026, [https://medium.com/oracledevs/kubeception-with-capoci-cluster-api-for-oci-part-1-14aa5124a4ee](https://medium.com/oracledevs/kubeception-with-capoci-cluster-api-for-oci-part-1-14aa5124a4ee)  
47. Common Policies \- Oracle Help Center, accessed on February 24, 2026, [https://docs.oracle.com/iaas/Content/Identity/Concepts/commonpolicies.htm](https://docs.oracle.com/iaas/Content/Identity/Concepts/commonpolicies.htm)  
48. Oracle Cloud Infrastructure GoldenGate Policies, accessed on February 24, 2026, [https://docs.oracle.com/iaas/goldengate/doc/policies.html](https://docs.oracle.com/iaas/goldengate/doc/policies.html)  
49. Matrix/Riot storage and performance requirements : r/selfhosted \- Reddit, accessed on February 24, 2026, [https://www.reddit.com/r/selfhosted/comments/g9h6au/matrixriot\_storage\_and\_performance\_requirements/](https://www.reddit.com/r/selfhosted/comments/g9h6au/matrixriot_storage_and_performance_requirements/)  
50. Summary of performance impact of running on resource constrained devices such as SBCs · Issue \#8428 · matrix-org/synapse \- GitHub, accessed on February 24, 2026, [https://github.com/matrix-org/synapse/issues/8428](https://github.com/matrix-org/synapse/issues/8428)  
51. matrix-construct/tuwunel: Official successor to conduwuit \- GitHub, accessed on February 24, 2026, [https://github.com/matrix-construct/tuwunel](https://github.com/matrix-construct/tuwunel)  
52. Reminder \- https://conduit.rs/ Rust implementation of the matrix server stack | Hacker News, accessed on February 24, 2026, [https://news.ycombinator.com/item?id=38163174](https://news.ycombinator.com/item?id=38163174)  
53. Building a serverless, post-quantum Matrix homeserver \- The Cloudflare Blog, accessed on February 24, 2026, [https://blog.cloudflare.com/serverless-matrix-homeserver-workers/](https://blog.cloudflare.com/serverless-matrix-homeserver-workers/)  
54. Scalable or not scalable · matrix-construct tuwunel · Discussion \#160 \- GitHub, accessed on February 24, 2026, [https://github.com/matrix-construct/tuwunel/discussions/160](https://github.com/matrix-construct/tuwunel/discussions/160)  
55. Matrix server software \- which one to choose? : r/selfhosted \- Reddit, accessed on February 24, 2026, [https://www.reddit.com/r/selfhosted/comments/1dp08qi/matrix\_server\_software\_which\_one\_to\_choose/](https://www.reddit.com/r/selfhosted/comments/1dp08qi/matrix_server_software_which_one_to_choose/)  
56. CPU/RAM Recommendations for Vaultwarden? \- Help, accessed on February 24, 2026, [https://vaultwarden.discourse.group/t/cpu-ram-recommendations-for-vaultwarden/1566](https://vaultwarden.discourse.group/t/cpu-ram-recommendations-for-vaultwarden/1566)  
57. How to deploy VaultWarden at an enterprise scale? : r/Bitwarden \- Reddit, accessed on February 24, 2026, [https://www.reddit.com/r/Bitwarden/comments/1cxuotp/how\_to\_deploy\_vaultwarden\_at\_an\_enterprise\_scale/](https://www.reddit.com/r/Bitwarden/comments/1cxuotp/how_to_deploy_vaultwarden_at_an_enterprise_scale/)  
58. Configuration | Docmost \- Documentation, accessed on February 24, 2026, [https://docmost.com/docs/self-hosting/configuration/](https://docmost.com/docs/self-hosting/configuration/)  
59. Backup on object stores \- CloudNativePG, accessed on February 24, 2026, [https://cloudnative-pg.io/docs/1.25/backup\_barmanobjectstore/](https://cloudnative-pg.io/docs/1.25/backup_barmanobjectstore/)  
60. Backup \- CloudNativePG, accessed on February 24, 2026, [https://cloudnative-pg.io/docs/1.25/backup/](https://cloudnative-pg.io/docs/1.25/backup/)  
61. Backup and Recovery \- CloudNativePG, accessed on February 24, 2026, [https://cloudnative-pg.io/documentation/1.18/backup\_recovery/](https://cloudnative-pg.io/documentation/1.18/backup_recovery/)  
62. Backup | CloudNativePG, accessed on February 24, 2026, [https://cloudnative-pg.io/docs/1.28/backup/](https://cloudnative-pg.io/docs/1.28/backup/)  
63. Object Storage Amazon S3 Compatibility API \- Oracle Help Center, accessed on February 24, 2026, [https://docs.oracle.com/en-us/iaas/Content/Object/Tasks/s3compatibleapi.htm](https://docs.oracle.com/en-us/iaas/Content/Object/Tasks/s3compatibleapi.htm)  
64. Using OCI Object Storage S3 Interface | ateam \- A-Team Chronicles, accessed on February 24, 2026, [https://www.ateam-oracle.com/using-oci-os-s3-interface](https://www.ateam-oracle.com/using-oci-os-s3-interface)  
65. Kubernetes Cluster Reference Architecture with Talos Linux for 2025-05 \- Sidero Labs, accessed on February 24, 2026, [https://www.siderolabs.com/wp-content/uploads/2025/08/Kubernetes-Cluster-Reference-Architecture-with-Talos-Linux-for-2025-05.pdf](https://www.siderolabs.com/wp-content/uploads/2025/08/Kubernetes-Cluster-Reference-Architecture-with-Talos-Linux-for-2025-05.pdf)