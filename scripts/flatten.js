const fs = require('fs');
const path = require('path');

async function flattenContract() {
  const nodeModulesPath = path.resolve(__dirname, '../node_modules');
  const sourcesPath = path.resolve(__dirname, '../contracts');
  
  const processedFiles = new Set();
  let flattenedContent = '';
  const licenses = new Set();
  const pragmas = new Set();

  function readFileContent(filePath) {
    try {
      return fs.readFileSync(filePath, 'utf8');
    } catch (error) {
      console.error(`Error reading file ${filePath}:`, error);
      return null;
    }
  }

  function processFile(filePath) {
    if (processedFiles.has(filePath)) {
      return '';
    }

    let content = '';
    const fileContent = readFileContent(filePath);
    if (!fileContent) return '';

    processedFiles.add(filePath);

    const lines = fileContent.split('\n');
    for (const line of lines) {
      // Collect SPDX license identifiers
      if (line.includes('SPDX-License-Identifier:')) {
        licenses.add(line.trim());
        continue;
      }

      // Collect pragma statements
      if (line.trim().startsWith('pragma')) {
        pragmas.add(line.trim() + ';');  // Add semicolon to pragma
        continue;
      }

      // Process imports
      if (line.trim().startsWith('import')) {
        const importMatch = line.match(/["']([^"']+)["']/);
        if (importMatch) {
          const importPath = importMatch[1];
          let fullPath;
          
          if (importPath.startsWith('@openzeppelin')) {
            fullPath = path.join(nodeModulesPath, importPath);
          } else {
            fullPath = path.join(path.dirname(filePath), importPath);
          }
          
          content += processFile(fullPath);
        }
        continue;
      }

      // Add other lines if they're not empty or comments
      const trimmedLine = line.trim();
      if (trimmedLine && !trimmedLine.startsWith('//')) {
        content += line + '\n';
      }
    }

    return content;
  }

  // Process main contract
  const mainContractPath = path.join(sourcesPath, 'Liberdus.sol');
  const flattenedCode = processFile(mainContractPath);

  // Combine everything
  let output = '';
  
  // Add SPDX license
  if (licenses.size > 0) {
    output += Array.from(licenses)[0] + '\n';
  }
  
  // Add pragma statements
  if (pragmas.size > 0) {
    output += Array.from(pragmas).join('\n') + '\n';
  }

  // Add a blank line after pragmas
  output += '\n';

  // Add flattened code
  output += flattenedCode;

  // Write to file
  fs.writeFileSync('Liberdus.flat.sol', output);
  console.log('Created flattened contract: Liberdus.flat.sol');
}

flattenContract()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });