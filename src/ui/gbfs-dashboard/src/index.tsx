import React from 'react';
import ReactDOM from 'react-dom/client';
import './styles/globals.css';  // Add this line
import App from './App';

const root = ReactDOM.createRoot(
  document.getElementById('root') as HTMLElement
);
root.render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);