import { themes as prismThemes } from "prism-react-renderer";
import type { Config } from "@docusaurus/types";
import type * as Preset from "@docusaurus/preset-classic";

const config: Config = {
  title: "react-native-nitro-unzip",
  tagline: "High-performance ZIP operations for React Native",
  favicon: "img/favicon.ico",

  url: "https://isaacrowntree.github.io",
  baseUrl: "/react-native-nitro-unzip/",

  organizationName: "isaacrowntree",
  projectName: "react-native-nitro-unzip",

  onBrokenLinks: "throw",

  markdown: {
    hooks: {
      onBrokenMarkdownLinks: "warn",
    },
  },

  i18n: {
    defaultLocale: "en",
    locales: ["en"],
  },

  plugins: [
    [
      "docusaurus-plugin-typedoc",
      {
        entryPoints: ["../src/index.ts"],
        tsconfig: "../tsconfig.json",
        readme: "none",
        outputFileStrategy: "members",
        indexFormat: "table",
        parametersFormat: "table",
        enumMembersFormat: "table",
        typeDeclarationFormat: "table",
        sidebar: {
          autoConfiguration: true,
          pretty: true,
        },
      },
    ],
  ],

  presets: [
    [
      "classic",
      {
        docs: {
          sidebarPath: "./sidebars.ts",
          editUrl:
            "https://github.com/isaacrowntree/react-native-nitro-unzip/tree/main/docs/",
        },
        blog: false,
        theme: {
          customCss: "./src/css/custom.css",
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    navbar: {
      title: "nitro-unzip",
      items: [
        {
          type: "docSidebar",
          sidebarId: "guideSidebar",
          position: "left",
          label: "Guides",
        },
        {
          type: "docSidebar",
          sidebarId: "apiSidebar",
          position: "left",
          label: "API Reference",
        },
        {
          href: "https://www.npmjs.com/package/react-native-nitro-unzip",
          label: "npm",
          position: "right",
        },
        {
          href: "https://github.com/isaacrowntree/react-native-nitro-unzip",
          label: "GitHub",
          position: "right",
        },
      ],
    },
    footer: {
      style: "dark",
      links: [
        {
          title: "Docs",
          items: [
            { label: "Getting Started", to: "/docs/getting-started" },
            { label: "API Reference", to: "/docs/api" },
          ],
        },
        {
          title: "More",
          items: [
            {
              label: "GitHub",
              href: "https://github.com/isaacrowntree/react-native-nitro-unzip",
            },
            {
              label: "npm",
              href: "https://www.npmjs.com/package/react-native-nitro-unzip",
            },
            {
              label: "Nitro Modules",
              href: "https://nitro.margelo.com/",
            },
          ],
        },
      ],
      copyright: `Copyright \u00a9 ${new Date().getFullYear()} Isaac Rowntree. Built with Docusaurus.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
      additionalLanguages: ["bash"],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
