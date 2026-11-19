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

local has(obj, field) = std.objectHas(obj, field) && obj[field] != null;

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

local resource(field, generator, name, derived={}) =
  std.mergePatch(
    std.mergePatch(
      generator(kube.hyphenate(name)) + com.makeMergeable(
        if has(params.default, field)
        then std.mergePatch(params.default[field], metadataNamespace(name))
        else metadataNamespace(name)
      ),
      derived
    ),
    if has(params.instances[name], field) then params.instances[name][field] else {}
  );

// All per-instance resources, generated in an instance-outer loop
local instanceResources = std.flatMap(
  function(instance)
    local name = instance.key;
    local gatewayName = resourceName('gateway', name);
    [
      resource('gateway', gw.Gateway, name, {
        spec: {
          infrastructure: {
            parametersRef: {
              group: 'microgateway.airlock.com',
              kind: 'GatewayParameters',
              name: resourceName('gatewayParameters', name),
            },
          },
        },
      }),
      resource('gatewayParameters', gw.GatewayParameters, name, {
        spec: {
          defaults: {
            sessionHandlingRef: {
              name: resourceName('sessionHandling', name),
            },
          },
        },
      }),
      withGatewayRefs(resource('httpRedirect', httpRoute, name), gatewayName),
      resource('pdb', pdb, name),
      resource('egressNetpol', egressNetpol, name, {
        spec: {
          podSelector: {
            matchLabels: {
              'gateway.networking.k8s.io/gateway-name': gatewayName,
            },
          },
        },
      }),
      resource('sessionHandling', gw.SessionHandling, name, {
        spec: {
          persistence: {
            redisProviderRef: {
              name: resourceName('redisProvider', name),
            },
          },
        },
      }),
      resource('redisProvider', gw.RedisProvider, name),
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
