import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

const config: Config = {
  title: 'EKS kube-proxy 모드 비교 분석',
  tagline: 'iptables vs ipvs vs nftables — conntrack sync 성능 실측 비교',
  favicon: 'img/favicon.ico',

  future: {
    v4: true,
  },

  markdown: {
    mermaid: true,
  },
  themes: ['@docusaurus/theme-mermaid'],

  url: 'https://whchoi98.github.io',
  baseUrl: '/eks-iptable/',

  organizationName: 'whchoi98',
  projectName: 'eks-iptable',
  deploymentBranch: 'gh-pages',
  trailingSlash: false,

  onBrokenLinks: 'warn',
  onBrokenMarkdownLinks: 'warn',

  i18n: {
    defaultLocale: 'ko',
    locales: ['ko'],
  },

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: './sidebars.ts',
          routeBasePath: '/',
          editUrl: 'https://github.com/whchoi98/eks-iptable/tree/master/website/',
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    colorMode: {
      defaultMode: 'dark',
      disableSwitch: false,
      respectPrefersColorScheme: false,
    },
    navbar: {
      title: 'EKS kube-proxy 분석',
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'mainSidebar',
          position: 'left',
          label: '가이드',
        },
        {
          href: 'https://github.com/whchoi98/eks-iptable',
          label: 'GitHub',
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: '문서',
          items: [
            { label: '소개', to: '/intro' },
            { label: '테스트 결과', to: '/results/sync-duration' },
          ],
        },
        {
          title: '참고',
          items: [
            { label: 'kube-proxy Modes', href: 'https://kubernetes.io/docs/reference/networking/virtual-ips/' },
            { label: 'EKS kube-proxy Add-on', href: 'https://docs.aws.amazon.com/eks/latest/userguide/managing-kube-proxy.html' },
            { label: 'nftables KEP-3866', href: 'https://github.com/kubernetes/enhancements/tree/master/keps/sig-network/3866-nftables-proxy' },
          ],
        },
        {
          title: '링크',
          items: [
            { label: 'GitHub', href: 'https://github.com/whchoi98/eks-iptable' },
            { label: 'AWSops', href: 'https://whchoi98.github.io/awsops/intro' },
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} Woo Hyung Choi. Built with Docusaurus.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
      additionalLanguages: ['bash', 'yaml', 'json'],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
