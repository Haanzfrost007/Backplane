const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');
const cors = require('cors');
const rateLimit = require('express-rate-limit');
require('dotenv').config();

const app = express();
const PORT = process.env.PORT || 8080;

// Helper function to ensure protocol
const ensureProtocol = (url) => {
    if (!url) return url;
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    return `http://${url}`;
};

// Habilitar CORS para permitir peticiones desde el frontend
app.use(cors());

// --- Rate Limiter ---
const paymentLimiter = rateLimit({
	windowMs: 10 * 1000, // 10 seconds
	limit: 5, // Limit each IP to 5 requests per windowMs
	standardHeaders: 'draft-7',
	legacyHeaders: false, 
    message: { message: '⛔ Too many payment requests, please try again later.' }
});

// --- Circuit Breaker State (In-Memory) ---
const paymentBreaker = {
    failures: 0,
    state: 'CLOSED', // CLOSED, OPEN, HALF-OPEN
    nextAttempt: 0,
    threshold: 3,
    cooldown: 10000 // 10 seconds cooldown
};

// --- Circuit Breaker Middleware ---
const checkPaymentBreaker = (req, res, next) => {
    if (paymentBreaker.state === 'OPEN') {
        if (Date.now() < paymentBreaker.nextAttempt) {
            console.log('🛡️ Circuit Breaker BLOCKED request to /payments');
            return res.status(503).json({ 
                message: 'Service Unavailable (Circuit Breaker OPEN)', 
                circuitBreaker: 'OPEN',
                retryAfter: Math.ceil((paymentBreaker.nextAttempt - Date.now()) / 1000)
            });
        } else {
            console.log('🛡️ Circuit Breaker entering HALF-OPEN state');
            paymentBreaker.state = 'HALF-OPEN';
        }
    }
    next();
};

// --- Proxy Event Handlers ---
const onProxyError = (err, req, res) => {
    paymentBreaker.failures++;
    console.log(`❌ Network Error on /payments. Failures: ${paymentBreaker.failures}`);
    
    if (paymentBreaker.failures >= paymentBreaker.threshold) {
        paymentBreaker.state = 'OPEN';
        paymentBreaker.nextAttempt = Date.now() + paymentBreaker.cooldown;
        console.log('🔥 Circuit Breaker TRIPPED to OPEN state');
    }

    res.status(503).json({ message: 'Service Unavailable (Network Error)', error: err.message });
};

const onProxyRes = (proxyRes, req, res) => {
    // Solo monitoreamos respuestas 500+ como fallos del servicio
    if (proxyRes.statusCode >= 500) {
        paymentBreaker.failures++;
        console.log(`⚠️ Payment Service Error ${proxyRes.statusCode}. Failures: ${paymentBreaker.failures}`);
        
        if (paymentBreaker.failures >= paymentBreaker.threshold) {
            paymentBreaker.state = 'OPEN';
            paymentBreaker.nextAttempt = Date.now() + paymentBreaker.cooldown;
            console.log('🔥 Circuit Breaker TRIPPED to OPEN state');
        }
    } else {
        // Éxito (2xx, 3xx, 4xx) -> Resetear breaker
        if (paymentBreaker.failures > 0 || paymentBreaker.state !== 'CLOSED') {
            console.log('✅ Payment Service Recovered. Circuit Breaker CLOSED.');
            paymentBreaker.failures = 0;
            paymentBreaker.state = 'CLOSED';
        }
    }
};

// --- Generic Proxy Error Handler ---
const genericErrorHandler = (serviceName) => (err, req, res) => {
    console.error(`❌ Network Error on /${serviceName}:`, err.message);
    res.status(503).json({ 
        message: `Service ${serviceName} Unavailable`, 
        error: err.message,
        suggestion: "Check if the service is awake (Cold Start) or if DNS is failing."
    });
};

// Rutas de proxy
// Auth Service
app.use('/auth', createProxyMiddleware({ 
    target: ensureProtocol(process.env.AUTH_SERVICE_URL) || 'http://auth-service:3000', 
    changeOrigin: true,
    pathRewrite: {
        '^/auth': '',
    },
    onError: genericErrorHandler('auth'),
    timeout: 30000, // 30s timeout
    proxyTimeout: 30000,
}));

// Payment Service (Uses Custom Circuit Breaker)
app.use('/payments', paymentLimiter, checkPaymentBreaker, createProxyMiddleware({ 
    target: ensureProtocol(process.env.PAYMENT_SERVICE_URL) || 'http://payment-service:3001', 
    changeOrigin: true,
    pathRewrite: {
        '^/payments': '',
    },
    onProxyRes: onProxyRes,
    onError: onProxyError,
    timeout: 30000,
    proxyTimeout: 30000,
}));

// Notification Service
app.use('/notifications', createProxyMiddleware({ 
    target: ensureProtocol(process.env.NOTIFICATION_SERVICE_URL) || 'http://notification-service:3002', 
    changeOrigin: true,
    pathRewrite: {
        '^/notifications': '',
    },
    onError: genericErrorHandler('notifications'),
    timeout: 30000,
    proxyTimeout: 30000,
}));

app.get('/health', (req, res) => {
    res.json({ status: 'API Gateway is running' });
});

app.get('/', (req, res) => {
    res.json({ 
        message: 'Welcome to the Microservices API Gateway',
        endpoints: {
            health: '/health',
            auth: '/auth',
            payments: '/payments',
            notifications: '/notifications'
        }
    });
});

app.listen(PORT, () => {
    console.log(`API Gateway running on port ${PORT}`);
});
