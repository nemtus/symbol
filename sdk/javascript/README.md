# @nemtus/symbol-sdk-typescript

Symbol SDK for TypeScript built with [official JavaScript SDK](https://github.com/symbol/symbol/tree/dev/sdk/javascript).

Note: Currently This is a very experimental level.
Note: This repository is a fork of [symbol/symbol](https://github.com/symbol/symbol) to create and maintain a temporal npm package of symbol-sdk for TypeScript.
Note: If you wanna refer the original Symbol Monorepo, please refer [https://github.com/symbol/symbol](https://github.com/symbol/symbol)

## For package users

### Install

```bash
npm install @nemtus/symbol-sdk-typescript

```

### Usage

Example to send a simple transfer transaction.

```typescript
import { SymbolFacade } from "@nemtus/symbol-sdk-typescript/esm/facade/SymbolFacade";
import { PrivateKey } from "@nemtus/symbol-sdk-typescript/esm/CryptoTypes";
import { KeyPair } from "@nemtus/symbol-sdk-typescript/esm/symbol/KeyPair";
import { Signature } from "@nemtus/symbol-sdk-typescript/esm/symbol/models";
import {
  Configuration,
  NetworkRoutesApi,
  TransactionRoutesApi,
} from "@nemtus/symbol-sdk-openapi-generator-typescript-axios";
import WebSocket from "ws";

const NODE_DOMAIN = "symbol-test.next-web-technology.com";

(async () => {
  // Call NetworkRoutesApi.getNetworkProperties to get epochAdjustment and networkCurrencyMosaicId.
  const configurationParameters = {
    basePath: `http://${NODE_DOMAIN}:3000`,
  };
  const configuration = new Configuration(configurationParameters);
  const networkRoutesApi = new NetworkRoutesApi(configuration);
  const networkPropertiesDTO = (await networkRoutesApi.getNetworkProperties()).data;

  // Remove s from the response of epochAdjustment and convert to number.
  const epochAdjustmentOriginal = networkPropertiesDTO.network.epochAdjustment;
  if (!epochAdjustmentOriginal) {
    throw Error("epochAdjustment is not found");
  }
  const epochAdjustment = parseInt(epochAdjustmentOriginal.replace(/s/g, ""));

  // Remove ' from the response of networkCurrencyMosaicId and convert to BigInt.
  const networkCurrencyMosaicIdOriginal =
    networkPropertiesDTO.chain.currencyMosaicId;
  if (!networkCurrencyMosaicIdOriginal) {
    throw Error("networkCurrencyMosaicId is not found");
  }
  const networkCurrencyMosaicId = BigInt(
    networkCurrencyMosaicIdOriginal.replace(/'/g, "")
  );

  // Call NetworkRoutesApi.getNetworkType to get network name to be placed in facade. (ex. "testnet")
  const networkTypeDTO = (await networkRoutesApi.getNetworkType()).data;
  if (!networkTypeDTO) {
    throw Error("networkType is not found");
  }
  const networkName = networkTypeDTO.name;

  // Initialize SDK with network name.
  const facade = new SymbolFacade(networkName);

  // Restore account to send a transaction.
  const privateKey = new PrivateKey("PUT_YOUR_PRIVATE_KEY_HERE");
  const keyPair = new KeyPair(privateKey);
  const signerPublicKeyString = keyPair.publicKey.toString();
  const signerAddressString = facade.network
    .publicKeyToAddress(keyPair.publicKey)
    .toString();

  // Calculate deadline. (The following sample means 2 hours.)
  const now = Date.now();
  const deadline = BigInt(now - epochAdjustment * 1000 + 2 * 60 * 60 * 1000);

  // Recipient Address
  const recipientAddressString = "TBK7XV2NHC466HZ63XC7RPESLNXFEGCSJ3ZZ2FY";

  // Create a transfer transaction data.
  const transaction = facade.transactionFactory.create({
    type: "transfer_transaction",
    signerPublicKey: signerPublicKeyString,
    deadline,
    recipientAddress: recipientAddressString,
    mosaics: [{ mosaicId: networkCurrencyMosaicId, amount: 1000000n }],
  });

  // Set fee.
  const feeMultiplier = 100;
  (transaction as any).fee.value = BigInt(
    (transaction as any).size * feeMultiplier
  );

  // Sign.
  const signature = facade.signTransaction(keyPair, transaction);
  (transaction as any).signature = new Signature(signature.bytes);

  // Set the generationHashSeed. (It is a network-specific value.)
  (transaction as any).network.generationHashSeed = facade.network;

  // Calculate transaction hash.
  const hash = facade.hashTransaction(transaction);
  console.log(hash.toString());
  console.log(`https://testnet.symbol.fyi/transactions/${hash.toString()}`);

  // Add signature to transaction data and create final data to announce. When you announce transaction, you need to use this value.
  const transactionPayload = (facade.transactionFactory.constructor as any).attachSignature(transaction, signature);

  // Transaction monitoring status.
  const confirmationHeight = 6; // ex. 6conf
  let transactionHeight = 0;
  let blockHeight = 0;
  let finalizedBlockHeight = 0;

  // Define websocket.
  const ws = new WebSocket(`wss://${NODE_DOMAIN}:3001/ws`);

  ws.on("open", () => {
    console.log("connection open");
  });

  ws.on("close", () => {
    console.log("connection closed");
  });

  ws.on("message", (msg: any) => {
    const res = JSON.parse(msg);
    if ("uid" in res) {
      console.log(`uid : ${res.uid}`);

      // Monitor target address related unconfirmed transaction.
      const unconfirmedBody = `{"uid": "${res.uid}", "subscribe": "unconfirmedAdded/${recipientAddressString}"}`;
      console.log(unconfirmedBody);
      ws.send(unconfirmedBody);

      // Monitor target address related confirmed transaction.
      const confirmedBody = `{"uid": "${res.uid}", "subscribe": "confirmedAdded/${recipientAddressString}"}`;
      console.log(confirmedBody);
      ws.send(confirmedBody);

      // Monitor target address related confirmed transaction.
      const statusBody = `{"uid": "${res.uid}", "subscribe": "status/${recipientAddressString}"}`;
      console.log(statusBody);
      ws.send(statusBody);

      // Monitor newly generated block.
      const blockBody = `{"uid": "${res.uid}", "subscribe": "block"}`;
      console.log(blockBody);
      ws.send(blockBody);

      // Monitor finalized block.
      const finalizedBlockBody = `{"uid": "${res.uid}", "subscribe": "finalizedBlock"}`;
      console.log(finalizedBlockBody);
      ws.send(finalizedBlockBody);
    }

    // Execute when unconfirmed transaction is detected.
    if (
      res.topic === `unconfirmedAdded/${recipientAddressString}` &&
      res.data.meta.hash === hash.toString()
    ) {
      console.log("transaction unconfirmed");
    }

    // Execute when confirmed transaction is detected.
    if (
      res.topic === `confirmedAdded/${recipientAddressString}` &&
      res.data.meta.hash === hash.toString()
    ) {
      console.log("transaction confirmed");
      transactionHeight = parseInt(res.data.meta.height);
    }

    // Execute when new block is generated.
    if (res.topic === `block`) {
      console.log("block");
      blockHeight = parseInt(res.data.block.height);
    }

    // Execute when a specified block is finalized.
    if (res.topic === `finalizedBlock`) {
      console.log("finalizedBlock");
      console.log(res);
      finalizedBlockHeight = parseInt(res.data.height);
    }

    // Execute when the transaction failed.
    if (
      res.topic === `status/${recipientAddressString}` &&
      res.data.hash === hash.toString()
    ) {
      console.log(res.data.code);
      ws.close();
    } else {
      console.log(res);
    }

    // After the blocks required for confirmation are generated, end to monitor.
    if (
      transactionHeight !== 0 &&
      transactionHeight + confirmationHeight - 1 <= blockHeight
    ) {
      console.log(
        `${confirmationHeight} blocks confirmed. transactionHeight is ${transactionHeight} blockHeight is ${blockHeight}.`
      );
      ws.close();
    } else {
      console.log(
        `wait for ${confirmationHeight} blocks. transactionHeight is ${transactionHeight} blockHeight is ${blockHeight}.`
      );
    }

    // After finalizedBlockHeight overtakes the transactionHeight, end monitoring.
    if (transactionHeight !== 0 && transactionHeight <= finalizedBlockHeight) {
      console.log(
        `${finalizedBlockHeight} block finalized. transactionHeight is ${transactionHeight} blockHeight is ${blockHeight}.`
      );
      ws.close();
    } else {
      console.log(
        `wait for finalized block. transactionHeight is ${transactionHeight} blockHeight is ${blockHeight}.`
      );
    }
  });

  // Announce transaction.
  try {
    const transactionRoutesApi = new TransactionRoutesApi(configuration);
    console.log(transactionPayload);
    const response = await transactionRoutesApi.announceTransaction({
      transactionPayload,
    });
    console.log(response.data);
  } catch (err) {
    console.error(err);
  }
})();

```

## For Developers

### Build for TypeScript

```bash
npm install
npm run build

```
