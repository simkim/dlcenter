const { useRef, useEffect } = React;

function QRCodeModal({ share, downloadHost, onClose }) {
  const containerRef = useRef(null);

  useEffect(() => {
    if (containerRef.current) {
      containerRef.current.innerHTML = '';
      const data = share.content || `${downloadHost}/share/${share.uuid}`;

      // qrcode-generator library API
      const typeNumber = 0; // auto-detect
      const errorCorrectionLevel = 'M';
      const qr = qrcode(typeNumber, errorCorrectionLevel);
      qr.addData(data);
      qr.make();

      // Create image - calculate cell size to fit ~280px
      const moduleCount = qr.getModuleCount();
      const cellSize = Math.floor(280 / moduleCount);
      const img = document.createElement('img');
      img.src = qr.createDataURL(cellSize, 0);
      containerRef.current.appendChild(img);
    }
  }, [share, downloadHost]);

  const handleBackdropClick = (e) => {
    if (e.target === e.currentTarget) {
      onClose();
    }
  };

  // Close on Escape key
  useEffect(() => {
    const handleEscape = (e) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', handleEscape);
    return () => document.removeEventListener('keydown', handleEscape);
  }, [onClose]);

  return (
    <div className="qrcode-modal qrcode-modal--visible" onClick={handleBackdropClick}>
      <div className="qrcode-modal__content">
        <button className="qrcode-modal__close" onClick={onClose} aria-label="Close">
          <span className="icon icon--times"></span>
        </button>
        <div className="qrcode-modal__image" ref={containerRef}></div>
        <div className="qrcode-modal__filename">{share.name}</div>
        <div className="qrcode-modal__hint">Scan to download</div>
      </div>
    </div>
  );
}

function Share({ share, localShares, downloadHost, onRemove, onShowQR }) {
  const canDelete = localShares[share.uuid];
  const isLink = share.link;
  const displayName = share.name.length > 45 ? share.name.substring(0, 45) + '...' : share.name;

  return (
    <div className="shares__share share">
      {canDelete && (
        <a className="share__remove icon icon--times icon--red" onClick={() => onRemove(share)}></a>
      )}
      {!isLink ? (
        <h3 className="share__name">{share.name}</h3>
      ) : (
        <h3 className="share__name share__link">
          <a href={share.name} target="_blank" rel="noopener noreferrer">{displayName}</a>
        </h3>
      )}
      <div className="share__filesize">{filesize(share.size || 0)}</div>
      <a className="share__qrcode" onClick={() => onShowQR(share)}>
        <span className="button__icon icon icon--qrcode"></span>
      </a>
      <a
        className="share__download button button--blue"
        download
        target="_blank"
        href={`${downloadHost}/share/${share.uuid}`}
      >
        <span className="button__icon icon icon--download"></span>
        Download
      </a>
    </div>
  );
}

function Header() {
  return (
    <header className="header">
      <h1 className="header__title">DL.center</h1>
      <div className="header__subtitle">Easily transfer files between nearby devices</div>
    </header>
  );
}

function SharesList({ remoteShares, localShares, downloadHost, onRemove, onShowQR }) {
  return (
    <div className="shares">
      <h2>Shared files</h2>
      {remoteShares.length === 0 ? (
        <div className="shares__share share share__empty">No shared files yet</div>
      ) : (
        remoteShares.map(share => (
          <Share
            key={share.uuid}
            share={share}
            localShares={localShares}
            downloadHost={downloadHost}
            onRemove={onRemove}
            onShowQR={onShowQR}
          />
        ))
      )}
      {remoteShares.length > 1 && (
        <a className="shares__download-all button button--blue" href={`${downloadHost}/all`}>
          <span className="button__icon icon icon--download"></span>
          Download All
        </a>
      )}
    </div>
  );
}

function FileUpload({ onFileSelect }) {
  const handleChange = (e) => {
    const files = e.target.files;
    for (let i = 0; i < files.length; i++) {
      onFileSelect(files[i]);
    }
    e.target.value = null;
  };

  return (
    <div className="uploads__upload file-upload">
      <h2 className="file-upload__header">Share a file</h2>
      <p>
        <label className="file-upload__button button button--green">
          <span className="button__icon icon icon--plus"></span>
          Select file
          <input
            type="file"
            className="file-upload__input"
            multiple
            onChange={handleChange}
          />
        </label>
      </p>
      <p>You can also drag and drop from your computer here.</p>
    </div>
  );
}

function TextUpload({ value, onChange, onShare }) {
  return (
    <div className="uploads__upload text-upload">
      <h2 className="text-upload__header">
        Share text
        <span className="text-upload__beta">beta</span>
      </h2>
      <p>
        <textarea
          className="text-upload__text"
          rows="4"
          value={value}
          onChange={(e) => onChange(e.target.value)}
        ></textarea>
      </p>
      <p>
        <button className="text-upload__button button button--green" onClick={onShare}>
          <span className="button__icon icon icon--plus"></span>
          Share
        </button>
      </p>
    </div>
  );
}

function HowTo() {
  return (
    <div className="howto">
      <h2 className="howto__header">How to use ?</h2>
      <p>
        Share a file, stay on this page.
        Open <a target="_blank" href="https://dl.center">dl.center</a> on another device
        using the same Internet connection. Click on download to retrieve your file!
      </p>
    </div>
  );
}

function Footer() {
  return (
    <div className="made-with">
      Made with <span className="icon icon--heart"></span> by{' '}
      <a target="_blank" href="https://twitter.com/gmonserand">@gmonserand</a>
      {' '}and{' '}
      <a target="_blank" href="https://twitter.com/genezys">@genezys</a>
    </div>
  );
}
