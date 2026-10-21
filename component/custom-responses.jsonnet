local kube = import 'kube-ssa-compat.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';

local inv = kap.inventory();

local cr = import 'lib/custom-responses.libsonnet';
local params = inv.parameters.airlock_microgateway;

local createCustomResponse(name, namespace, customResponseConfig) =
  assert std.isObject(customResponseConfig) : 'You cannot set an error response to null. It is still referenced from the GatewayParameters';
  kube._Object('microgateway.airlock.com/v1alpha1', 'CustomResponse', name) {
    spec: customResponseConfig,
    metadata+: {
      namespace: namespace,
    },
  };

local mapCustomResponses = std.flatMap(
  function(instanceName)
    local specs = cr.specsFor(instanceName);
    [ { instance: instanceName, responseName: name, customResponse: specs[name] } for name in std.objectFields(specs) ],
  std.objectFields(params.instances)
);

{
  ['custom-responses/%s/%s' % [ entry.instance, entry.responseName ]]: createCustomResponse(entry.responseName, entry.instance, entry.customResponse)
  for entry in mapCustomResponses
}
