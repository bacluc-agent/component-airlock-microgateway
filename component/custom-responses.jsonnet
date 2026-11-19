local kube = import 'kube-ssa-compat.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';

local inv = kap.inventory();

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
    local instanceValue = params.instances[instanceName];
    local instanceCustomResponses = if instanceValue != null && std.objectHas(instanceValue, 'customResponses') then instanceValue.customResponses else {};
    local patchedResponses = std.mergePatch(params.default.customResponses, instanceCustomResponses);
    local toEntry = function(customResponseKeyValue) {
      instance: instanceName,
      responseName: customResponseKeyValue.key,
      customResponse: customResponseKeyValue.value,
    };
    std.map(toEntry, std.objectKeysValues(patchedResponses)),
  std.objectFields(params.instances)
);

{
  ['custom-responses/%s/%s' % [ entry.instance, entry.responseName ]]: createCustomResponse(entry.responseName, entry.instance, entry.customResponse)
  for entry in mapCustomResponses
}
