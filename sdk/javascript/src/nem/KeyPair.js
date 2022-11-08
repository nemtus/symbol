import tweetnacl from './external/tweetnacl-nacl-fast-keccak.js';
import { PrivateKey, PublicKey, Signature } from '../CryptoTypes.js';
import { deepCompare } from '../utils/arrayHelpers.js';
import { isCanonicalS } from '../utils/cryptoHelpers.js';

/**
 * Represents an ED25519 private and public key.
 */
export class KeyPair {
	/**
	 * Creates a key pair from a private key.
	 * @param {PrivateKey} privateKey Private key.
	 */
	constructor(privateKey) {
		this._privateKey = privateKey;

		const reversedPrivateKeyBytes = new Uint8Array([...privateKey.bytes]);
		reversedPrivateKeyBytes.reverse();
		this._keyPair = tweetnacl.sign.keyPair.fromSeed(reversedPrivateKeyBytes);
	}

	/**
	 * Gets the public key.
	 * @returns {PublicKey} Public key.
	 */
	get publicKey() {
		return new PublicKey(this._keyPair.publicKey);
	}

	/**
	 * Gets the private key.
	 * @returns {PrivateKey} Private key.
	 */
	get privateKey() {
		return new PrivateKey(this._privateKey.bytes);
	}

	/**
	 * Signs a message with the private key.
	 * @param {Uint8Array} message Message to sign.
	 * @returns {Signature} Message signature.
	 */
	sign(message) {
		return new Signature(tweetnacl.sign.detached(message, this._keyPair.secretKey));
	}
}

/**
 * Verifies signatures signed by a single key pair.
 */
export class Verifier {
	/**
	 * Creates a verifier from a public key.
	 * @param {PublicKey} publicKey Public key.
	 */
	constructor(publicKey) {
		if (0 === deepCompare(new Uint8Array(PublicKey.SIZE), publicKey.bytes))
			throw new Error('public key cannot be zero');

		this.publicKey = publicKey;
	}

	/**
	 * Verifies a message signature.
	 * @param {Uint8Array} message Message to verify.
	 * @param {Signature} signature Signature to verify.
	 * @returns {boolean} true if the message signature verifies.
	 */
	verify(message, signature) {
		return tweetnacl.sign.detached.verify(message, signature.bytes, this.publicKey.bytes)
			&& isCanonicalS(signature.bytes.subarray(32, 64));
	}
}
