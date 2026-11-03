"""Create/validate public app routing only. Never handles the Google secret."""
import argparse
import json
import os
import pathlib
import re
import urllib.parse

def validate(data):
    assert set(data) == {'installed'}, 'Public config must contain only installed'
    c = data['installed']
    assert set(c) == {'client_id', 'token_proxy'}, 'Only public client ID and proxy URL may be bundled'
    assert re.fullmatch(r'[A-Za-z0-9_-]+\.apps\.googleusercontent\.com', c['client_id']), 'Invalid Google client ID'
    u = urllib.parse.urlsplit(c['token_proxy'])
    assert u.scheme == 'https' and u.hostname and '.' in u.hostname and u.path == '/v1/token', 'Use the deployed HTTPS /v1/token URL'
    assert not u.username and not u.password and not u.query and not u.fragment and u.port in (None,443), 'Invalid proxy URL'
    assert u.hostname != 'localhost' and not u.hostname.endswith('.local') and not re.fullmatch(r'[0-9.:]+',u.hostname), 'Proxy must use a public hostname'
    return data

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('path'); parser.add_argument('--from-env', action='store_true'); args = parser.parse_args()
    path = pathlib.Path(args.path)
    if args.from_env:
        client = os.environ.get('MINUTES_GOOGLE_CLIENT_ID',''); proxy = os.environ.get('MINUTES_GOOGLE_AUTH_URL','')
        assert bool(client) == bool(proxy), 'Set both public Google build variables, or neither'
        if client:
            data=validate({'installed':{'client_id':client,'token_proxy':proxy}})
            path.write_text(json.dumps(data,indent=2)+'\n')
    if path.exists():
        validate(json.loads(path.read_text())); print('Public Google routing validated; no registration secret or user tokens bundled.')
    else:
        print('Hosted Google sign-in not configured; existing imported clients remain available.')
