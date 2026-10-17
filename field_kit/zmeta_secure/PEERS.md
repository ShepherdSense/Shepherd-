# Peer registry (gateway operator keeps this)

One row per Shepherd mesh. The tunnel IP is the identity the gateway
sees; `platform_id` is the identity the EVENTS claim. The gateway MUST
check they match (see zmeta_deployment.md) — otherwise any peer could
spoof another mesh's detections.

| Tunnel IP  | Mesh public key (first 16 chars…) | platform_id      | Party / unit      | Added    |
|------------|-----------------------------------|------------------|-------------------|----------|
| 10.99.0.11 | …                                 | shepherd-mesh-a  |                   |          |
| 10.99.0.12 | …                                 | shepherd-mesh-b  |                   |          |
| 10.99.0.13 | …                                 | shepherd-mesh-c  |                   |          |

Rules:
- One platform_id per mesh, never reused across meshes.
- platform_id is set in Shepherd → Settings → ZMeta export → Platform ID.
- If a mesh's private key is ever suspected compromised: delete its
  [Peer] block on the gateway, generate a fresh keypair on the mesh
  (re-run NEW_MESH_KEY.bat after deleting mesh.key/mesh.pub), register
  the new public key. Old key stops working immediately.
