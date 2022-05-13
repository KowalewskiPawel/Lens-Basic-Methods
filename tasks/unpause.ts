import { task } from 'hardhat/config';
import { LensHub__factory } from '../typechain-types';
import { ProtocolState, waitForTx, initEnv, getAddrs } from './helpers/utils';

// eslint-disable-next-line no-empty-pattern
task('unpause', 'unpaused the protocol').setAction(async ({}, hre) => {
  const [governance] = await initEnv(hre);
  const addrs = getAddrs();
  const lensHub = LensHub__factory.connect(addrs['lensHub proxy'], governance);

  console.log(await lensHub.getState());
  await waitForTx(lensHub.setState(ProtocolState.Unpaused));
  console.log(await lensHub.getState());
});
