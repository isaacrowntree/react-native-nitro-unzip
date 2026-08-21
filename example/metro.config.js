const { getDefaultConfig } = require('expo/metro-config');
const path = require('path');

const projectRoot = __dirname;
// The library repo root. It is NOT an npm workspace — see CONTRIBUTING — so
// only its source is shared with the app, never its node_modules.
const libraryRoot = path.resolve(projectRoot, '..');

const config = getDefaultConfig(projectRoot);

// Watch the library source so edits to src/ hot-reload without a rebuild.
config.watchFolders = [path.join(libraryRoot, 'src')];

// Resolve every package from the app's own node_modules. The library is
// installed via `file:..`, so Metro follows that symlink into the repo root and
// would otherwise walk up into the *library's* node_modules and load a second
// copy of react-native / react — which produces "Attempted to import the module
// ... not listed in the exports" warnings and duplicate-runtime bugs.
// (Hierarchical lookup stays on — Expo nests packages like @expo/log-box
// inside its own node_modules and needs the upward walk to find them.)
config.resolver.nodeModulesPaths = [path.resolve(projectRoot, 'node_modules')];
// The library is installed via `file:..`, so Metro follows that symlink into
// the repo root and walks up into the LIBRARY's node_modules — loading a second
// copy of react-native / react. Block that directory outright so every import,
// including deep subpaths like react-native/src/private/..., resolves against
// the app's own tree.
config.resolver.blockList = [
  new RegExp(
    `^${path.join(libraryRoot, 'node_modules').replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\/.*$`,
  ),
];

config.resolver.extraNodeModules = {
  react: path.resolve(projectRoot, 'node_modules/react'),
  'react-native': path.resolve(projectRoot, 'node_modules/react-native'),
  'react-native-nitro-modules': path.resolve(
    projectRoot,
    'node_modules/react-native-nitro-modules',
  ),
};

module.exports = config;
