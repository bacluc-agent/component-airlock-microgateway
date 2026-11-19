// main template for airlock-microgateway
local kube = import 'kube-ssa-compat.libsonnet';
local gw = import 'lib/airlock-microgateway-operator.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';

local inv = kap.inventory();

// The hiera parameters for the component
local params = inv.parameters.airlock_microgateway;
local has_cilium = std.member(inv.applications, 'cilium');

local metadataNamespace(name) = {
  metadata: {
    namespace: name,
  },
};

local has(obj, field) = obj != null && std.objectHas(obj, field) && obj[field] != null;

// main template for airlock-microgateway
local httpRoute(name='') = {
  apiVersion: 'gateway.networking.k8s.io/v1',
  kind: 'HTTPRoute',
  metadata: {
    namespace: name,
    name: name,
  },
  spec: {},
};

local pdb(name='') = {
  apiVersion: 'policy/v1',
  kind: 'PodDisruptionBudget',
  metadata: {
    namespace: name,
    name: name,
    labels: {
      'gateway.networking.k8s.io/gateway-name': name,
    },
  },
};

local egressNetpol(name='') = {
  apiVersion: 'networking.k8s.io/v1',
  kind: 'NetworkPolicy',
  metadata: {
    namespace: name,
    name: name,
  },
};

local namespaces = {
  ['%s/Namespace' % instance.key]: kube.Namespace(instance.key) {
    metadata+: {
      labels+: { 'openshift.io/cluster-monitoring': 'true' },
    },
  } + {
    metadata+: {
      labels+: com.makeMergeable(params.default.namespace.labels),
      annotations: com.makeMergeable(params.default.namespace.annotations),
    },
  }
  for instance in std.objectKeysValues(params.instances)
};

// The final name of a resource, derived from the instance name unless the
// user overrides metadata.name in the instance parameters.
local resourceName(field, name) =
  if has(params.instances[name], field)
     && has(params.instances[name][field], 'metadata')
     && has(params.instances[name][field].metadata, 'name')
  then params.instances[name][field].metadata.name
  else if has(params.default, field)
          && has(params.default[field], 'metadata')
          && has(params.default[field].metadata, 'name')
  then params.default[field].metadata.name
  else kube.hyphenate(name);

local CiliumNetworkPolicy(name) = {
  apiVersion: 'cilium.io/v2',
  kind: 'CiliumNetworkPolicy',
  metadata: {
    name: name,
  },
};

local GatewayCNPEgress(namespace, gatewayName) =
  CiliumNetworkPolicy(namespace) {
    metadata: {
      name: 'internal-dns-egress',
      namespace: namespace,
    },
    spec: {
      endpointSelector: {
        matchLabels: {
          'gateway.networking.k8s.io/gateway-name': gatewayName,
          'microgateway.airlock.com/managedBy': params.operatorNamespace,
        },
      },
      egress: [
        {
          toEndpoints: [
            {
              matchLabels: {
                'dns.operator.openshift.io/daemonset-dns': 'default',
                'k8s:io.kubernetes.pod.namespace': 'openshift-dns',
              },
            },
          ],
          toPorts: [
            {
              ports: [
                {
                  port: '5353',
                  protocol: 'UDP',
                },
              ],
              rules: {
                dns: [
                  {
                    matchPattern: '*',
                  },
                ],
              },
            },
          ],
        },
      ],
    },
  };

local GatewayCNPIngress(namespace, gatewayName) =
  CiliumNetworkPolicy(namespace) {
    metadata: {
      name: 'allow-ingress-world',
      namespace: namespace,
    },
    spec: {
      endpointSelector: {
        matchLabels: {
          'gateway.networking.k8s.io/gateway-name': gatewayName,
          'microgateway.airlock.com/managedBy': params.operatorNamespace,
        },
      },
      ingress: [
        {
          fromEntities: [ 'world' ],
        },
      ],
    },
  };

local toFiles(objects) = {
  ['%s/%s-%s' % [ object.metadata.namespace, object.kind, object.metadata.name ]]: object
  for object in objects
};

// Fill in the derived Gateway name for each parentRef that doesn't set one.
local withGatewayRefs(route, gatewayName) =
  if has(route, 'spec') && has(route.spec, 'parentRefs') then
    route {
      spec+: {
        parentRefs: [
          ref + (if has(ref, 'name') then {} else { name: gatewayName })
          for ref in route.spec.parentRefs
        ],
      },
    }
  else
    route;

// All per-instance resources, generated in an instance-outer loop
local instanceResources = std.flatMap(
  function(instance)
    local name = instance.key;
    local gatewayName = resourceName('gateway', name);
    [
      std.mergePatch(
        std.mergePatch(
          gw.Gateway(kube.hyphenate(name)) + com.makeMergeable(
            if has(params.default, 'gateway')
            then std.mergePatch(params.default.gateway, metadataNamespace(name))
            else metadataNamespace(name)
          ),
          {
            spec: {
              infrastructure: {
                parametersRef: {
                  group: 'microgateway.airlock.com',
                  kind: 'GatewayParameters',
                  name: resourceName('gatewayParameters', name),
                },
              },
            },
          }
        ),
        if has(params.instances[name], 'gateway') then params.instances[name].gateway else {}
      ),
      std.mergePatch(
        std.mergePatch(
          gw.GatewayParameters(kube.hyphenate(name)) + com.makeMergeable(
            if has(params.default, 'gatewayParameters')
            then std.mergePatch(params.default.gatewayParameters, metadataNamespace(name))
            else metadataNamespace(name)
          ),
          {
            spec: {
              defaults: {
                sessionHandlingRef: {
                  name: resourceName('sessionHandling', name),
                },
              },
            },
          }
        ),
        if has(params.instances[name], 'gatewayParameters') then params.instances[name].gatewayParameters else {}
      ),
      withGatewayRefs(
        std.mergePatch(
          std.mergePatch(
            httpRoute(kube.hyphenate(name)) + com.makeMergeable(
              if has(params.default, 'httpRedirect')
              then std.mergePatch(params.default.httpRedirect, metadataNamespace(name))
              else metadataNamespace(name)
            ),
            {}
          ),
          if has(params.instances[name], 'httpRedirect') then params.instances[name].httpRedirect else {}
        ),
        gatewayName
      ),
      std.mergePatch(
        std.mergePatch(
          pdb(kube.hyphenate(name)) + com.makeMergeable(
            if has(params.default, 'pdb')
            then std.mergePatch(params.default.pdb, metadataNamespace(name))
            else metadataNamespace(name)
          ),
          {}
        ),
        if has(params.instances[name], 'pdb') then params.instances[name].pdb else {}
      ),
      std.mergePatch(
        std.mergePatch(
          egressNetpol(kube.hyphenate(name)) + com.makeMergeable(
            if has(params.default, 'egressNetpol')
            then std.mergePatch(params.default.egressNetpol, metadataNamespace(name))
            else metadataNamespace(name)
          ),
          {
            spec: {
              podSelector: {
                matchLabels: {
                  'gateway.networking.k8s.io/gateway-name': gatewayName,
                },
              },
            },
          }
        ),
        if has(params.instances[name], 'egressNetpol') then params.instances[name].egressNetpol else {}
      ),
      std.mergePatch(
        std.mergePatch(
          gw.SessionHandling(kube.hyphenate(name)) + com.makeMergeable(
            if has(params.default, 'sessionHandling')
            then std.mergePatch(params.default.sessionHandling, metadataNamespace(name))
            else metadataNamespace(name)
          ),
          {
            spec: {
              persistence: {
                redisProviderRef: {
                  name: resourceName('redisProvider', name),
                },
              },
            },
          }
        ),
        if has(params.instances[name], 'sessionHandling') then params.instances[name].sessionHandling else {}
      ),
      std.mergePatch(
        std.mergePatch(
          gw.RedisProvider(kube.hyphenate(name)) + com.makeMergeable(
            if has(params.default, 'redisProvider')
            then std.mergePatch(params.default.redisProvider, metadataNamespace(name))
            else metadataNamespace(name)
          ),
          {}
        ),
        if has(params.instances[name], 'redisProvider') then params.instances[name].redisProvider else {}
      ),
    ] + if has_cilium then [
      GatewayCNPIngress(name, gatewayName),
      GatewayCNPEgress(name, gatewayName),
    ] else [],
  std.objectKeysValues(params.instances)
);

// Define outputs below
toFiles(instanceResources) +
namespaces
+ (import 'custom-responses.jsonnet')
+ (import 'lib/debug.jsonnet')
