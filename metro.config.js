const path = require('node:path');
const {getDefaultConfig, mergeConfig} = require('@react-native/metro-config');
const escapeRegex = value => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
// Scope exclusions to this checkout: the checkout itself may live under work/.
const blockList = ['Vendor', 'build', 'work', 'Pods'].map(directory =>
  new RegExp(`^${escapeRegex(path.join(__dirname, directory))}[/\\\\].*`),
);
module.exports = mergeConfig(getDefaultConfig(__dirname), {
  // Bound bundle workers when native compilers or a simulator share the host.
  maxWorkers: 2,
  resolver: {blockList},
});
