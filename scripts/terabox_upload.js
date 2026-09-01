const fs = require('fs');
const path = require('path');
const TeraboxUploader = require('terabox-upload-tool');

function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Variável obrigatória ausente: ${name}`);
  return value;
}

async function ensureDirectory(uploader, remoteDir) {
  const parts = remoteDir.split('/').filter(Boolean);
  let current = '';

  for (const part of parts) {
    current += `/${part}`;
    try {
      const listing = await uploader.fetchFileList(current);
      if (listing && listing.success !== false) continue;
    } catch (_) {
      // Se a pasta ainda não existir, tentamos criá-la abaixo.
    }

    try {
      await uploader.createDirectory(current);
    } catch (error) {
      // Uma corrida ou resposta não-padrão pode ocorrer se a pasta já existir.
      // Confirmamos pela listagem antes de considerar erro real.
      const check = await uploader.fetchFileList(current);
      if (!check || check.success === false) throw error;
    }
  }
}

async function remoteFileInfo(uploader, remoteDir, fileName) {
  const response = await uploader.fetchFileList(remoteDir);
  const list = response?.data?.list || response?.list || [];
  return list.find((item) => item.server_filename === fileName || item.name === fileName) || null;
}

(async () => {
  const ndus = required('TERABOX_NDUS');
  const jsToken = required('TERABOX_JS_TOKEN');
  const appId = process.env.TERABOX_APP_ID || '250528';
  const localFile = required('LOCAL_FILE');
  const remoteDir = required('REMOTE_DIR');

  if (!fs.existsSync(localFile)) {
    throw new Error(`Arquivo local não encontrado: ${localFile}`);
  }

  const fileName = path.basename(localFile);
  const localSize = fs.statSync(localFile).size;

  const uploader = new TeraboxUploader({ ndus, jsToken, appId });

  await ensureDirectory(uploader, remoteDir);

  const existing = await remoteFileInfo(uploader, remoteDir, fileName);
  if (existing) {
    const existingPath = existing.path || `${remoteDir}/${fileName}`;
    await uploader.deleteFiles([existingPath]);
  }

  let lastPercent = -1;
  const result = await uploader.uploadFile(
    localFile,
    (loaded, total) => {
      const percent = total ? Math.floor((loaded / total) * 100) : 0;
      if (percent !== lastPercent && (percent % 10 === 0 || percent === 100)) {
        console.log(`TeraBox upload: ${percent}%`);
        lastPercent = percent;
      }
    },
    remoteDir
  );

  if (result && result.success === false) {
    throw new Error(result.message || 'O TeraBox recusou o upload.');
  }

  const remote = await remoteFileInfo(uploader, remoteDir, fileName);
  if (!remote) {
    throw new Error('Upload terminou, mas o arquivo não apareceu na pasta remota.');
  }

  const remoteSize = Number(remote.size ?? remote.server_size ?? -1);
  if (remoteSize >= 0 && remoteSize !== localSize) {
    throw new Error(`Tamanho remoto divergente: local=${localSize}, remoto=${remoteSize}.`);
  }

  console.log(`TERABOX_OK=${remoteDir}/${fileName}`);
})().catch((error) => {
  console.error(`TERABOX_ERROR=${error?.message || String(error)}`);
  process.exit(1);
});
