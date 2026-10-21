// Derives CustomResponse resources and GatewayParameters customResponses
// references from single customResponses entries with a status-code matcher.
local kap = import 'lib/kapitan.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.airlock_microgateway;

local has(obj, field) = std.objectHas(obj, field) && obj[field] != null;

local defaultCustomResponses = if has(params.default, 'customResponses') then params.default.customResponses else {};

local instanceCustomResponses(instanceName) =
  local instance = params.instances[instanceName];
  if has(instance, 'customResponses') then instance.customResponses else {};

local isMatcherEntry(entry) = std.objectHas(entry, 'matcher') && entry.matcher != null;

// Entries respond to two shapes: legacy entries are a CustomResponse spec
// verbatim, new entries carry a optional-matcher plus a
// `<contentType>: <content>` map. Instance-level entries merge into the
// default entry per JSON merge patch so inherited matchers survive content
// overrides, and a `null` value removes the entry.
local mergedEntries(instanceName) =
  local instanceValues = instanceCustomResponses(instanceName);
  local mergedEntry(key) =
    local target = if std.objectHas(defaultCustomResponses, key) then defaultCustomResponses[key] else {};
    local patch = if std.objectHas(instanceValues, key) then instanceValues[key] else {};
    std.mergePatch(target, patch);
  {
    [key]: mergedEntry(key)
    for key in std.setUnion(std.objectFields(defaultCustomResponses), std.objectFields(instanceValues))
    if mergedEntry(key) != null
  };

local assertMatcher(matcher, responseName) =
  local fields = std.objectFields(matcher);
  assert std.length(fields) == 1 && (fields[0] == 'exact' || fields[0] == 'range') : 'matcher of customResponses entry %s must contain exactly one of "exact" or "range"' % [ responseName ];
  matcher;

local matcherEntries(instanceName) = [
  {
    responseName: entry.key,
    matcher: assertMatcher(entry.value.matcher, entry.key),
  }
  for entry in std.objectKeysValues(mergedEntries(instanceName))
  if isMatcherEntry(entry.value)
];

local localMatcher(matcher) = matcher;

local upstreamMatcher(matcher) =
  if std.objectHas(matcher, 'range') then {
    range: {
      start: matcher.range.from,
      end: matcher.range.to,
    },
  } else matcher;

// CustomResponse spec for an entry: new-shape entries expand their
// `<contentType>: <content>` map into a `content` list and drop the matcher;
// legacy entries stay verbatim.
local specFor(entry) =
  if std.objectHas(entry, 'customResponses') then {
    content: [
      { contentType: contentType } + entry.customResponses[contentType]
      for contentType in std.objectFields(entry.customResponses)
    ],
  } else entry;

// The CustomResponse spec source for an entry: a legacy entry set on the
// instance wins verbatim, a new-shape instance entry extends the default
// content map, otherwise the default entry decides.
local specEntry(instanceName, key) =
  local instanceValues = instanceCustomResponses(instanceName);
  if std.objectHas(instanceValues, key) && instanceValues[key] != null && std.objectHas(instanceValues[key], 'customResponses') then mergedEntries(instanceName)[key]
  else if std.objectHas(instanceValues, key) && instanceValues[key] != null then instanceValues[key]
  else defaultCustomResponses[key];

local localRefs(instanceName) = [
  {
    statusCodeCondition: {
      matcher: localMatcher(find.matcher),
    },
    customResponseRef: {
      name: find.responseName,
    },
  }
  for find in matcherEntries(instanceName)
];

local upstreamRefs(instanceName) = [
  {
    responseConditions: {
      statusCode: {
        matcher: upstreamMatcher(find.matcher),
      },
    },
    customResponseRef: {
      name: find.responseName,
    },
  }
  for find in matcherEntries(instanceName)
];

{
  hasMatcherEntries(instanceName):: std.length(matcherEntries(instanceName)) > 0,
  specsFor(instanceName):: { [key]: specFor(specEntry(instanceName, key)) for key in std.objectFields(mergedEntries(instanceName)) },
  localRefs(instanceName):: localRefs(instanceName),
  upstreamRefs(instanceName):: upstreamRefs(instanceName),
  gatewayParametersCustomResponses(instanceName)::
    if std.length(matcherEntries(instanceName)) > 0 then {
      customResponses: {
        'local': localRefs(instanceName),
        upstream: upstreamRefs(instanceName),
      },
    } else {},
}
