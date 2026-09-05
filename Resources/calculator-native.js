/* Native worker adapter; accepts JSON data only. No JavaScript from the query is executed. */
const switcharooCalculate = createSwitcharooCalculator(math);
const switcharooGraphFunctions = new Set('sin cos tan asin acos atan sinh cosh tanh abs sqrt cbrt exp log log10 log2 floor ceil round min max pow'.split(' '));
function switcharooGraph(expression, xmin, xmax, parameter) {
  try {
    const text = expression.trim().replace(/^y\s*=\s*/, '').replace(/π/g, 'pi').replace(/×/g, '*');
    if (!text) return {points:[]};
    if (text.length > 250) throw Error('Expression is too long');
    const tree = math.parse(text); let count = 0;
    tree.traverse(node => {
      if (++count > 70) throw Error('Expression is too long');
      if (!['OperatorNode','FunctionNode','SymbolNode','ConstantNode','ParenthesisNode'].includes(node.type)) throw Error('Use y = f(x)');
      if (node.type === 'FunctionNode' && !switcharooGraphFunctions.has(node.fn.name)) throw Error('Unknown function');
      if (node.type === 'SymbolNode' && !switcharooGraphFunctions.has(node.name) && !['x','a','pi','e'].includes(node.name)) throw Error('Use x or parameter a');
      if (node.type === 'OperatorNode' && node.fn === 'factorial') throw Error('Factorial is not graphed');
    });
    const compiled = tree.compile(), points = [];
    for (let i = 0; i <= 600; i++) {
      const x = xmin + (xmax - xmin) * i / 600;
      let y; try { y = compiled.evaluate({x, a:parameter}); } catch { y = NaN; }
      points.push([x, typeof y === 'number' && Number.isFinite(y) ? y : null]);
    }
    return {points};
  } catch (e) { return {points:[], error:e.message}; }
}
function switcharooNativeCalculate(json) {
  try {
    const request = JSON.parse(json);
    if (request.mode === 'graph') {
      const {xmin,xmax,a} = request;
      if (![xmin,xmax,a].every(Number.isFinite) || xmax <= xmin || xmax-xmin < 1e-6 || xmax-xmin > 1e8) throw Error('Graph range is too large');
      if (!Array.isArray(request.expressions) || request.expressions.length > 6) throw Error('Use up to six expressions');
      return JSON.stringify({curves:request.expressions.map(text => switcharooGraph(String(text),xmin,xmax,a))});
    }
    const query = String(request.query || '');
    if (query.length > 400) return JSON.stringify({result:{value:'Expression is too long',raw:'',kind:'Calculation',error:true}});
    return JSON.stringify({result:switcharooCalculate(query, request.now ? {now:new Date(request.now)} : {})});
  } catch { return JSON.stringify({error:'Check expression'}); }
}
