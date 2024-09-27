const https = require('https');
const setCookie = require('set-cookie-parser');
const fs = require('fs');

const input_json = process.argv[2];
const data = fs.readFileSync(input_json, 'utf8')
    .replace(/\\n/g,'')     // the content var from ansible has \n
    .replace(/\\\"/g,'\"'); // contains and escaped "
let config = JSON.parse(data);

const CLIENT_ID = config.client_id;
const JITSI_API_BASE = config.jitsi_api_base;
const JITSI_API = `https://${JITSI_API_BASE}`;
const STANDALONE_BASE_URL =  config.standalone_base_url;
const STANDALONE_NONCE = config.standalone_nonce;
const STANDALONE_WEB_URL = config.standalone_web_url;

/**
 * Retrieves the cookie from auth0 '/co/authenticate' endpoint.
 * And calls convertAuth0Token passing the cookie.
 * @param username
 * @param password
 */
function retrieveToken(username, password, callback) {
    // console.log('retrieveToken for', username);

    const cookie_retrieve_data = JSON.stringify({
        client_id: CLIENT_ID,
        credential_type: 'http://auth0.com/oauth/grant-type/password-realm',
        username,
        password,
        realm: 'Username-Password-Authentication'
    });

    const cookie_retrieve_options = {
        hostname: STANDALONE_BASE_URL,
        port: 443,
        path: '/co/authenticate',
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'Content-Length': cookie_retrieve_data.length,
            'Origin': STANDALONE_WEB_URL
        }
    };

    const cookie_retrieve_req = https.request(cookie_retrieve_options, (request) => {
        request.on('error', (err) => {
            console.log(err);
            process.exit(-1);
        }).on('data', () => {
        }).on('end', () => {
            const cookies = setCookie.parse(request, {
                map: true
            });

            if (cookies.auth0) {
                convertAuth0Token(cookies.auth0.value, callback);
            } else {
                console.error("No cookie found!", request)
                process.exit(-2);
            }
        })
    })

    cookie_retrieve_req.write(cookie_retrieve_data)
    cookie_retrieve_req.end()
}

/**
 * Hits auth0 '/authorize' endpoint passing the auth0 cookie we received.
 * Calls retrieveJitsiToken with the access token found.
 * @param auth0Token
 */
function convertAuth0Token(auth0Token, callback) {
    const token_retrieve_options = {
        hostname: STANDALONE_BASE_URL,
        port: 443,
        path: `/authorize?client_id=${CLIENT_ID}&response_type=token%20id_token&redirect_uri=${STANDALONE_WEB_URL}&scope=openid%20profile%20email&audience=${JITSI_API}&nonce=${STANDALONE_NONCE}&response_mode=web_message&prompt=none&auth0Client=eyJuYW1lIjoibG9jay5qcyIsInZlcnNpb24iOiIxMS4xOS4wIiwiZW52Ijp7ImF1dGgwLmpzIjoiOS4xMi4wIn19`,
        method: 'GET',
        headers: {
            'Cookie': `auth0=${auth0Token}`
        }
    };
    const token_retrieve_req = https.request(token_retrieve_options, (request) => {
        const body = [];

        request.on('error', (err) => {
            console.log(err);
            process.exit(-3);
        }).on('data', (chunk) => {
            body.push(chunk);
        }).on('end', () => {
            const found = Buffer.concat(body).toString().match('"access_token":"((?<=")[^"]+(?=")|([^\\s]+))"');
            if (found) {
                retrieveJitsiToken(found[1], callback);
            } else {
                console.error("No token returned from /authorize!")
                process.exit(-4);
            }
        });
    });
    token_retrieve_req.end()
}

/**
 * Retrieves the jitsi token from api-vo.jitsi.net the '/v1/meeting/standalone-token' endpoint, using the auth0 token.
 * @param auth0Token
 */
function retrieveJitsiToken(auth0Token, callback) {
    const jitsi_token_retrieve_options = {
        hostname: JITSI_API_BASE,
        port: 443,
        path: '/v1/meeting/standalone-token',
        method: 'GET',
        headers: {
            'authority': JITSI_API_BASE,
            'accept': 'application/json, text/plain, /',
            'authorization': `Bearer ${auth0Token}`,
            'user-agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36',
            'origin': STANDALONE_WEB_URL,
            'sec-fetch-site': ' cross-site',
            'sec-fetch-mode': ' cors',
            'sec-fetch-dest': ' empty',
            'referer': STANDALONE_WEB_URL,
            'accept-language': ' en-US,en;q=0.9'
        }
    };

    const jitsi_token_req = https.request(jitsi_token_retrieve_options, (request) => {
        const body = [];

        request.on('error', (err) => {
            console.log(err);
            process.exit(-5);
        }).on('data', (chunk) => {
            body.push(chunk);
        }).on('end', () => {
            // process.stdout.write(JSON.parse(Buffer.concat(body).toString()).token)
            // process.stdout.write('\n')
            // process.exit(0);
            callback(JSON.parse(Buffer.concat(body).toString()).token);
        });
    });
    jitsi_token_req.end()

}

// we will reuse the source json as a result, deleting some unused data, so making a copy of it
const result = JSON.parse(JSON.stringify(config.credentials));
let waiting = 0;
const complete = () => {
    if (!waiting) {
        console.log(JSON.stringify(result));
    }
};

let timeout = 1000;
Object.entries(config.credentials).forEach(([key, value]) => {
    Object.entries(config.credentials[key]).forEach(([ckey, cvalue]) => {
        if (ckey.startsWith('participant')) {
            delete result[key][ckey].password;
            delete result[key][ckey].username;
            setTimeout(function() {
                waiting++;
                retrieveToken(cvalue.username, cvalue.password, (jwt) => {
                    result[key][ckey].jwt = jwt;
                    waiting --;
                    complete();
                });
            }, timeout);
            timeout += 1000;
        }
    });
});
