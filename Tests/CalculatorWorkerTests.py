"""Behavioral fixtures from Raycast's manual/changelog and direct Raycast comparisons.
Direct Raycast observations are explicitly marked; remaining cases are math/spec tests.
No test drives Raycast's UI.
"""
import json
import subprocess
import sys
import time

worker = subprocess.Popen([sys.argv[1], '--calculator-worker'], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, text=True)
checks = 0
try:
    assert json.loads(worker.stdout.readline()) == {'ready': True}
    def request(**query):
        query.setdefault('locale', 'en_US')
        worker.stdin.write(json.dumps(query) + '\n')
        worker.stdin.flush()
        return json.loads(worker.stdout.readline())
    # Captured from Raycast 1.104.28 on 2026-09-05, before UI testing was stopped.
    raycast_observed = [
        ('(1GB per second ) in Mb', '8,000 Mbit/s'),
        ('1 GB per minute in Mb', '133.3333333333 Mbit/s'),
        ('1 GB/s in MB', '1,000 MB/s'), ('1 GB in Mb', '8,000 Mbit'),
        ('1 Gbps in MB/s', '125 MB/s'), ('1000 / 3', '333.3333333333'),
        ('0.1+0.2', '0.3'), ('sin(90)', '0.8939966636'),
        ('sin(90 degrees)', '1'), ('2 rem in px', '32px')]
    mathematical = [
        ('100 Mbps to MB/s', '12.5 MB/s'), ('1 GiB in MiB', '1,024 MiB'),
        ('2 + 3 * 4', '14'), ('(2 + 3) * 4', '20'),
        ('square root of 625', '25'), ('cube root of 27', '3'), ('2 power 10', '1,024'),
        ('52% of 900', '468'), ('20% off 80', '64'), ('15% tip on 42', '6.3'),
        ('ratio of 3 to 5', '0.6'), ('3% of $123', '$3.69'),
        ('20 celsius in fahrenheit', '68 °F'), ('10ft in m', '3.048 m'),
        ('1 kg + 250 g', '1.25 kg'), ('2 inches in px at 72 ppi', '144px'),
        ('145 mins to timespan', '2 hours 25 min'), ('55h in workdays', '6.875 workdays'),
        ('3 workdays in hours', '24 hours'), ('workhours in 2023', '2,080 hours'),
        ('10K', '10,000'), ('USD1K', '$1,000.00'), ('54 minutes at 1.5x', '36 min'),
        ('savings required for $10k/month @ 5.6%', '$2.143M'), ('1k on 100k', '1%'),
        ('cot(pi/4)', '1'), ('csch(1)', '0.8509181282'), ('3:45pm + 5', '8:45 PM'),
        ('#ff0000', '#ff0000'), ('ff0000', '#ff0000'),
        ('rgb(255, 0, 0) in hsl', 'hsl(0, 100%, 50%)'), ('hwb(0 0% 0%)', '#ff0000'),
        ('lab(54.29% 80.82 69.88) in hex', '#ff0000'),
        ('lch(54.29% 106.84 40.85) in rgb', 'rgb(255, 0, 0)'),
        ('rgba(255, 0, 0, 0.5)', '#ff000080')]
    durations = []
    for query, value in raycast_observed + mathematical:
        start = time.monotonic()
        answer = request(query=query).get('result')
        durations.append((time.monotonic() - start) * 1000)
        assert answer and answer['value'] == value, (query, answer, value)
        checks += 1
    assert request(query='0.1 + 0.2')['result']['raw'] == '0.3'; checks += 1
    assert request(query='1,2 + 3,4', locale='de_DE')['result']['value'] == '4,6'; checks += 1
    assert request(query='2 rem in px', rem=20)['result']['value'] == '40px'; checks += 1
    assert request(query='1 1/2 pounds', automaticUnits=False)['result']['value'] == '1 lb 8 oz'; checks += 1
    # Source/target swapping retains the original quantity, as a unit-swap action should.
    assert request(query='10ft in m')['result']['swap'] == '10 m in ft'; checks += 1
    for query in ['1kg to seconds', '3m + 5kg', '1/0']:
        answer = request(query=query)
        assert answer.get('error') or not answer.get('result'), (query, answer)
        checks += 1
    for query in ['2+', '(2+2', '1 GB in']:
        assert request(query=query).get('incomplete'), query; checks += 1
    for query in ['Dia', 'My Schedule', 'Timers', 'Figma 2']:
        assert not request(query=query).get('result'), query; checks += 1
    for query in ['100 USD in GBP', '1 BTC in USD']:
        answer = request(query=query)
        assert answer.get('currencyRequests') and not answer.get('result'), (query,answer)
        checks += 1
    assert request(query='100 USD in GBP', rates={'USD-GBP':'0.75'})['result']['raw'] == '75 GBP'; checks += 1
    assert request(query='1 BTC in USD', rates={'USD-BTC':'0.00002'})['result']['raw'] == '50000 USD'; checks += 1
    # These depend on the current date/time, so require a recognized result rather than a frozen clock.
    for query in ['5pm ldn in sf', 'days until Christmas', 'lunar day', 'time in JFK',
                  'time in São Paulo', 'time diff Paris', 'time in 4 hours in San Francisco', 'monday in 3 weeks']:
        answer = request(query=query).get('result')
        assert answer and answer['kind'] in ['Date & time','Duration','Unit conversion','Calculation'], (query, answer)
        checks += 1
    # At 17:00 London, SF is never 17:00 (the earlier unrecognized-alias regression).
    assert request(query='5pm ldn in sf')['result']['value'] != '5:00 PM'; checks += 1
    curves = request(mode='graph', expressions=['y = x^2', 'sin(x)', 'a*x', '1/x'], xmin=-10, xmax=10, a=2)['curves']
    assert len(curves) == 4 and all(len(c['points']) == 601 for c in curves)
    assert curves[0]['points'][300] == [0, 0] and curves[0]['points'][-1] == [10, 100]
    assert curves[2]['points'][-1] == [10, 20] and curves[3]['points'][300][1] is None
    checks += 3
    for expression in ['import("x")', 'x = 2', '[1,2,3]', 'window.alert(1)']:
        assert request(mode='graph', expressions=[expression], xmin=-10, xmax=10, a=1)['curves'][0]['error']
        checks += 1
    assert request(query='x' * 401)['error']; checks += 1
    print(f'{checks} native calculator checks passed ({len(raycast_observed)} exact Raycast comparisons); warm median {sorted(durations)[len(durations)//2]:.2f}ms')
finally:
    worker.stdin.close()
    worker.wait(timeout=5)
