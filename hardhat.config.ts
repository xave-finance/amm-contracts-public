require('dotenv').config()

import '@typechain/hardhat'
import '@openzeppelin/hardhat-upgrades'
import '@nomiclabs/hardhat-waffle'
import '@nomiclabs/hardhat-etherscan'
import '@nomiclabs/hardhat-ethers'
import 'hardhat-gas-reporter'
import 'hardhat-tracer'
import 'solidity-coverage'

const INFURA_PROJECT_ID = process.env.INFURA_PROJECT_ID || ''
const MNEMONIC_SEED = process.env.MNEMONIC_SEED || ''
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY || ''
const POLYSCAN_API_KEY = process.env.POLYSCAN_API_KEY || ''
const ARBISCAN_API_KEY = process.env.ARBISCAN_API_KEY || ''
const ALCHEMY_API_KEY = process.env.ALCHEMY_PROJECT_ID || ''

/**
 * @type import('hardhat/config').HardhatUserConfig
 */

export default {
  solidity: {
    compilers: [
      // {
      //   version: '0.7.1',
      //   settings: {
      //     optimizer: {
      //       enabled: true,
      //       runs: 10000,
      //     },
      //   },
      // },
      {
        version: '0.7.3',
        settings: {
          optimizer: {
            enabled: true,
            runs: 10000, // default value 10_000
          },
        },
      },
      {
        version: '0.7.6',
        settings: {
          optimizer: {
            enabled: true,
            runs: 10000, // default value 10_000
          },
        },
      },
      // {
      //   version: '0.8.0',
      //   settings: {
      //     optimizer: {
      //       enabled: true,
      //       runs: 7500,
      //     },
      //   },
      // },
    ],
    overrides: {
      'contracts/balancer-core-v2/vault/Vault.sol': {
        version: '0.7.1',
        settings: {
          optimizer: {
            enabled: true,
            runs: 400,
          },
        },
      },
      'contracts/balancer-core-v2/pools/weighted/WeightedPoolFactory.sol': {
        version: '0.7.1',
        settings: {
          optimizer: {
            enabled: true,
            runs: 800,
          },
        },
      },
    },
  },
  networks: {
    //hardhat: {
    //	chainId: 1337,
    //	// forking: {
    //	// 	url: `https://eth-kovan.alchemyapi.io/v2/${ALCHEMY_API_KEY}`,
    //	// 	blockNumber: 29238122,
    //	// 	// blockNumber: 28764216,
    //	// },
    //	//forking: {
    //	//	enabled: true,
    //	//	url: `https://eth-mainnet.alchemyapi.io/v2/${ALCHEMY_API_KEY}`,
    //	//	blockNumber: 13453242,
    //	//},
    //	accounts: {
    //		accountsBalance: '100000000000000000000000', // 100000 ETH
    //		count: 5,
    //	},
    //},

    hardhat: {
      chainId: 1337,
      forking: {
        enabled: true,
        url: `https://polygon-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}`,
      },
      accounts: {
        mnemonic: MNEMONIC_SEED,
      },
      allowUnlimitedContractSize: true,
    },
    kovan: {
      url: `https://kovan.infura.io/v3/${INFURA_PROJECT_ID}`,
      accounts: {
        mnemonic: MNEMONIC_SEED,
      },
      blockGasLimit: 20000000,
    },
    rinkeby: {
      url: `https://rinkeby.infura.io/v3/${INFURA_PROJECT_ID}`,
      accounts: {
        mnemonic: MNEMONIC_SEED,
      },
      blockGasLimit: 20000000,
    },
    matic: {
      chainId: 137,
      //url: `https://polygon-mainnet.infura.io/v3/${INFURA_PROJECT_ID}`,
      url: `https://polygon-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}`,
      accounts: {
        mnemonic: MNEMONIC_SEED,
      },
      // gasPrice: 8000000000,
      blockGasLimit: 20000000,
    },
    arb: {
      chainId: 42161,
      url: `https://arbitrum-mainnet.infura.io/v3/${INFURA_PROJECT_ID}`,
      accounts: {
        mnemonic: MNEMONIC_SEED,
      },
    },
    sepolia: {
      chainId: 11155111,
      url: `https://sepolia.infura.io/v3/${INFURA_PROJECT_ID}`,
      accounts: {
        mnemonic: MNEMONIC_SEED,
      },
    },
    mainnet: {
      url: `https://eth-mainnet.alchemyapi.io/v2/${ALCHEMY_API_KEY}`,
      chainId: 1,
      accounts: {
        mnemonic: MNEMONIC_SEED,
      },
    },
    avalanche: {
      url: `https://avalanche-mainnet.infura.io/v3/${INFURA_PROJECT_ID}`,
      chainId: 43114,
      accounts: {
        mnemonic: MNEMONIC_SEED,
      },
    },
    localhost: {
      chainId: 1337,
      url: 'http://127.0.0.1:8545/',
      accounts: {
        mnemonic: MNEMONIC_SEED,
      },
    },
  },
  etherscan: {
    apiKey: {
      polygon: POLYSCAN_API_KEY, // change this to the network api key you are deploying to
      avalanche: 'avascan', // apiKey is not required, just set a placeholder,
      mainnet: ETHERSCAN_API_KEY,
    },
    customChains: [
      {
        network: 'avalanche',
        chainId: 43114,
        urls: {
          apiURL: 'https://api.avascan.info/v2/network/mainnet/evm/43114/etherscan',
          browserURL: 'https://avascan.info',
        },
      },
    ],
  },
}
