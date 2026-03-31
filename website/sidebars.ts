import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

const sidebars: SidebarsConfig = {
  mainSidebar: [
    'intro',
    {
      type: 'category',
      label: '테스트 환경',
      collapsed: false,
      items: [
        'environment/architecture',
        'environment/cluster-setup',
        'environment/monitoring',
        'environment/workload',
      ],
    },
    {
      type: 'category',
      label: '테스트 결과',
      collapsed: false,
      items: [
        'results/sync-duration',
        'results/load-test',
        'results/conntrack',
        'results/scaleout',
      ],
    },
    {
      type: 'category',
      label: '모드별 심층 분석',
      items: [
        'deep-dive/iptables',
        'deep-dive/ipvs',
        'deep-dive/nftables',
      ],
    },
    'conclusion',
    {
      type: 'category',
      label: '운영 가이드',
      items: [
        'operations/quick-start',
        'operations/known-issues',
      ],
    },
  ],
};

export default sidebars;
