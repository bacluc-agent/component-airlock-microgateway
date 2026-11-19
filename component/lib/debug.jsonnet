local kube = import '../kube-ssa-compat.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.airlock_microgateway;


local debugConfigMap(namespace, instanceParams) = kube._Object('v1', 'ConfigMap', 'debug-configmap') {
  metadata+: {
    namespace: namespace,
  },
  data: {
    debug: |||
      %s
    ||| % [ std.manifestYamlDoc(instanceParams, indent_array_in_object=false, quote_keys=false) ],
  },
};

{
  [if params.debug then 'debug/%s' % instance.key]: debugConfigMap(instance.key, std.mergePatch(params.default, if instance.value == null then {} else instance.value))
  for instance in std.objectKeysValues(params.instances)
}
