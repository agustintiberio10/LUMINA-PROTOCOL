// Uso: node script/GenerateMerkleRoot.js investors-seed.json
// Input: JSON con lista de inversores [{address, amount}]
// Output: merkle root + proofs para cada inversor
//
// NOTA: Requiere @openzeppelin/merkle-tree (npm install @openzeppelin/merkle-tree)
// No se corre ahora — es para cuando se cierren las rondas

const { StandardMerkleTree } = require("@openzeppelin/merkle-tree");
const fs = require("fs");

// Leer archivo de inversores
const investorsFile = process.argv[2] || "investors-seed.json";
const investors = JSON.parse(fs.readFileSync(investorsFile, "utf8"));

// Formato: [[address, amountInWei], ...]
const entries = investors.map(inv => [
    inv.address,
    BigInt(inv.amount * 1e18).toString()
]);

// Generar tree
const tree = StandardMerkleTree.of(entries, ["address", "uint256"]);

console.log("\n=== MERKLE ROOT ===");
console.log(tree.root);

console.log("\n=== PROOFS PER INVESTOR ===");
for (const [i, v] of tree.entries()) {
    const proof = tree.getProof(i);
    console.log(`\nInvestor: ${v[0]}`);
    console.log(`Amount: ${v[1]} wei (${Number(v[1]) / 1e18} LUMINA)`);
    console.log(`Proof: ${JSON.stringify(proof)}`);
}

// Guardar tree completo
const outputFile = investorsFile.replace(".json", "-tree.json");
fs.writeFileSync(outputFile, JSON.stringify(tree.dump(), null, 2));
console.log(`\nTree saved to ${outputFile}`);

// Guardar proofs individuales
const proofsOutput = {};
for (const [i, v] of tree.entries()) {
    proofsOutput[v[0]] = {
        amount: v[1],
        proof: tree.getProof(i)
    };
}
const proofsFile = investorsFile.replace(".json", "-proofs.json");
fs.writeFileSync(proofsFile, JSON.stringify(proofsOutput, null, 2));
console.log(`Proofs saved to ${proofsFile}`);
