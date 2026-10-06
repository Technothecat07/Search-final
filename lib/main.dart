import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const apiNote = 'Local dataset bundled from Student Search Tool v16';

String norm(dynamic v) => (v ?? '').toString().trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
List<String> words(String v) => RegExp(r'[a-z0-9]+').allMatches(norm(v)).map((m) => m.group(0)!).toList();

// Levenshtein-based similarity, matching the intent/thresholds of the desktop tool.
double similarity(String a, String b) {
  final x=a, y=b;
  if (x==y) return 1;
  if (x.isEmpty || y.isEmpty) return 0;
  final prev=List<int>.generate(y.length+1,(i)=>i), cur=List<int>.filled(y.length+1,0);
  for (var i=1;i<=x.length;i++) {
    cur[0]=i;
    for (var j=1;j<=y.length;j++) {
      final cost=x.codeUnitAt(i-1)==y.codeUnitAt(j-1)?0:1;
      cur[j]=math.min(math.min(cur[j-1]+1,prev[j]+1),prev[j-1]+cost);
    }
    for(var j=0;j<=y.length;j++) prev[j]=cur[j];
  }
  return 1-(prev[y.length]/math.max(x.length,y.length));
}

bool similarMatch(String value,String query){
  final qw=words(query), vw=words(value);
  if(qw.isEmpty || vw.isEmpty) return false;
  for(final q in qw){
    if(q.length<3) continue;
    final threshold=q.length>=6?0.76:0.82;
    if(vw.any((v)=>similarity(q,v)>=threshold)) return true;
  }
  return false;
}

bool matchText(String value,String query,String mode){
  final v=norm(value), q=norm(query);
  if(q.isEmpty) return false;
  if(mode=='Exact text') return RegExp(r'(?<![a-z0-9])'+RegExp.escape(q)+r'(?![a-z0-9])').hasMatch(v);
  return v.contains(q);
}

bool dateMatch(String value,String query,String mode){
  final q=norm(query),v=norm(value);
  if(!RegExp(r'^\d{4}(?:-\d{2})?(?:-\d{2})?$').hasMatch(q)) return matchText(v,q,mode);
  if(mode=='Exact text') return v==q || (q.length==4 && v.startsWith('$q-')) || (q.length==7 && v.startsWith('$q-'));
  return v.contains(q);
}

double? numberValue(String v){
  final m=RegExp(r'-?\d+(?:\.\d+)?').firstMatch(v.replaceAll(',',''));
  return m==null?null:double.tryParse(m.group(0)!);
}

class FilterState {
  String typed='';
  String mode='Exact text';
  Set<String> selected={};
  String low='', high='';
}

class SignalApp extends StatefulWidget { const SignalApp({super.key}); @override State<SignalApp> createState()=>_SignalAppState(); }
class _SignalAppState extends State<SignalApp>{
  List<Map<String,dynamic>> records=[];
  List<Map<String,dynamic>> filtered=[];
  Map<String,String> labels={};
  Map<String,List<String>> groups={};
  List<String> dateFields=[];
  List<String> numFields=[];
  Map<String,List<String>> detailScopes={};
  final nameCtl=TextEditingController(), detailCtl=TextEditingController();
  String nameMode='Contains', detailMode='Contains', detailScope='School + College + Parents';
  bool similar=false, dark=false, loading=true, filtersOpen=false;
  final Map<String,FilterState> filters={};
  int? selectedIndex;
  String status='Loading…';
  final searchFocus=FocusNode();

  @override void initState(){super.initState(); _load();}
  @override void dispose(){nameCtl.dispose();detailCtl.dispose();searchFocus.dispose();super.dispose();}
  Future<void> _load() async {
    final p=await SharedPreferences.getInstance();
    dark=p.getBool('dark')??true;
    final r=jsonDecode(await rootBundle.loadString('assets/data/records.json')) as List;
    final m=jsonDecode(await rootBundle.loadString('assets/data/meta.json')) as Map;
    labels=Map<String,String>.from(m['labels']);
    groups=(m['groups'] as Map).map((k,v)=>MapEntry(k,List<String>.from(v)));
    dateFields=List<String>.from(m['dateFields']); numFields=List<String>.from(m['numFields']);
    detailScopes=(m['detailScopes'] as Map).map((k,v)=>MapEntry(k,List<String>.from(v)));
    records=r.map((e)=>Map<String,dynamic>.from(e)).toList(); filtered=List.of(records);
    for(final f in labels.keys) filters[f]=FilterState();
    setState(()=>loading=false); _runSearch();
  }
  void _theme(bool v) async { final p=await SharedPreferences.getInstance(); await p.setBool('dark',v); setState(()=>dark=v); }
  List<String> get scopeFields => detailScopes[detailScope]??detailScopes['All details']??labels.keys.toList();
  bool _activeFilters(){return filters.values.any((f)=>f.typed.trim().isNotEmpty||f.selected.isNotEmpty||f.low.trim().isNotEmpty||f.high.trim().isNotEmpty);}

  void _runSearch(){
    if(loading)return;
    final nq=nameCtl.text.trim(), dq=detailCtl.text.trim();
    final out=<Map<String,dynamic>>[];
    for(final r in records){
      var ok=true;
      if(nq.isNotEmpty){
        final hit=matchText('${r['name']??''}',nq,nameMode);
        final sim=similar&&similarMatch('${r['name']??''}',nq);
        if(!hit&&!sim) ok=false;
      }
      if(ok&&dq.isNotEmpty){
        var hit=false;
        for(final f in scopeFields){ if(matchText('${r[f]??''}',dq,detailMode)|| (similar&&similarMatch('${r[f]??''}',dq))){hit=true;break;} }
        if(!hit) ok=false;
      }
      if(ok){
        for(final entry in filters.entries){
          final f=entry.key, s=entry.value;
          if(s.typed.trim().isEmpty&&s.selected.isEmpty&&s.low.trim().isEmpty&&s.high.trim().isEmpty) continue;
          final val='${r[f]??''}'.trim(); var hit=false;
          if(s.low.isNotEmpty||s.high.isNotEmpty){
            final x=numberValue(val), lo=numberValue(s.low), hi=numberValue(s.high);
            hit=x!=null&&(lo==null||x>=lo)&&(hi==null||x<=hi);
          } else {
            if(s.typed.isNotEmpty) hit=(dateFields.contains(f)?dateMatch(val,s.typed,s.mode):matchText(val,s.typed,s.mode));
            if(!hit&&s.selected.isNotEmpty) hit=s.selected.any((x)=>matchText(val,x,s.mode));
          }
          if(!hit){ok=false;break;}
        }
      }
      if(ok) out.add(r);
    }
    setState((){filtered=out;selectedIndex=null;status='${out.length.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'),(m)=>'${m[1]},')} result${out.length==1?'':'s'}';});
  }

  Future<void> _chooseValues(String field) async {
    final s=filters[field]!;
    final values=records.map((r)=>'${r[field]??''}'.trim()).where((v)=>v.isNotEmpty&&v!='-').toSet().toList()..sort((a,b)=>norm(a).compareTo(norm(b)));
    final temp=Set<String>.from(s.selected);
    final result=await showModalBottomSheet<Set<String>>(context:context,isScrollControlled:true,backgroundColor:Theme.of(context).colorScheme.surface,builder:(ctx){
      var q='';
      return StatefulBuilder(builder:(ctx,set){
        final shown=values.where((v)=>norm(v).contains(norm(q))).toList();
        return SafeArea(child:Padding(padding:const EdgeInsets.fromLTRB(16,10,16,12),child:SizedBox(height:MediaQuery.of(ctx).size.height*.82,child:Column(children:[
          Row(children:[Expanded(child:Text(labels[field]??field,style:const TextStyle(fontSize:18,fontWeight:FontWeight.w700))),Text('${temp.length} selected')]),
          const SizedBox(height:10),TextField(decoration:const InputDecoration(prefixIcon:Icon(Icons.search),hintText:'Find a value…'),onChanged:(v)=>set(()=>q=v)),
          const SizedBox(height:8),Row(children:[TextButton(onPressed:()=>set(()=>temp.addAll(shown)),child:const Text('Select shown')),TextButton(onPressed:()=>set(()=>temp.clear()),child:const Text('Clear')),const Spacer(),TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(ctx,temp),child:const Text('APPLY & SAVE'))]),
          const Divider(),Expanded(child:ListView.builder(itemCount:shown.length,itemBuilder:(_,i){final v=shown[i];final checked=temp.contains(v);return CheckboxListTile(value:checked,onChanged:(x)=>set(()=>x==true?temp.add(v):temp.remove(v)),title:Text(v),dense:true,controlAffinity:ListTileControlAffinity.leading);}))
        ]))));
      });
    });
    if(result!=null){setState(()=>s.selected=result);_runSearch();}
  }

  Future<void> _filtersSheet(){
    return showModalBottomSheet(context:context,isScrollControlled:true,backgroundColor:Theme.of(context).colorScheme.surface,builder:(ctx)=>DraggableScrollableSheet(expand:false,initialChildSize:.88,minChildSize:.55,maxChildSize:.96,builder:(_,scroll){return StatefulBuilder(builder:(ctx,set){
      return Padding(padding:const EdgeInsets.fromLTRB(14,8,14,8),child:Column(children:[
        Row(children:[const Expanded(child:Text('Filters',style:TextStyle(fontSize:20,fontWeight:FontWeight.w800))),TextButton(onPressed:(){for(final s in filters.values){s.typed='';s.selected.clear();s.low='';s.high='';}set((){});},child:const Text('CLEAR ALL')),FilledButton(onPressed:(){Navigator.pop(ctx);_runSearch();},child:const Text('APPLY FILTERS'))]),
        Expanded(child:ListView(controller:scroll,children:groups.entries.map((g)=>ExpansionTile(title:Text(g.key,style:const TextStyle(fontWeight:FontWeight.w700)),children:g.value.map((f){final s=filters[f]!;final multi=records.map((r)=>'${r[f]??''}'.trim()).where((v)=>v.isNotEmpty&&v!='-').toSet().length<=80;return Padding(padding:const EdgeInsets.symmetric(horizontal:8,vertical:4),child:Column(children:[Row(children:[Expanded(child:Text(labels[f]??f)),if(s.selected.isNotEmpty)Padding(padding:const EdgeInsets.only(right:6),child:Text('${s.selected.length}',style:TextStyle(color:Theme.of(ctx).colorScheme.primary,fontWeight:FontWeight.bold))),PopupMenuButton<String>(initialValue:s.mode,itemBuilder:(_)=>const [PopupMenuItem(value:'Exact text',child:Text('Exact text')),PopupMenuItem(value:'Contains',child:Text('Contains'))],onSelected:(v)=>set(()=>s.mode=v),icon:const Icon(Icons.unfold_more,size:20))]),
              if(numFields.contains(f)) Row(children:[Expanded(child:TextField(decoration:const InputDecoration(labelText:'Minimum'),onChanged:(v)=>s.low=v)),const SizedBox(width:8),Expanded(child:TextField(decoration:const InputDecoration(labelText:'Maximum'),onChanged:(v)=>s.high=v))]) else Row(children:[Expanded(child:TextField(controller:TextEditingController(text:s.typed),decoration:InputDecoration(hintText:'Type ${labels[f]?.toLowerCase()??f}…'),onChanged:(v){s.typed=v;})),if(multi)IconButton(tooltip:'Select values',onPressed:()=>_chooseValues(f),icon:const Icon(Icons.tune))]),
            ]);}).toList())).toList()))
      ]));
    });}));
  }

  Future<void> _export() async {
    if(filtered.isEmpty){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('No results to save.')));return;}
    final selected=Set<String>{'regno','name','branch'};
    final chosen=await showModalBottomSheet<Set<String>>(context:context,isScrollControlled:true,builder:(ctx){return StatefulBuilder(builder:(ctx,set){return SafeArea(child:Padding(padding:const EdgeInsets.all(16),child:SizedBox(height:MediaQuery.of(ctx).size.height*.8,child:Column(children:[Row(children:[const Expanded(child:Text('Save results',style:TextStyle(fontSize:20,fontWeight:FontWeight.w800))),TextButton(onPressed:()=>set(()=>selected.addAll(labels.keys)),child:const Text('ALL')),TextButton(onPressed:()=>set(()=>selected.clear()),child:const Text('NONE'))]),const Divider(),Expanded(child:ListView(children:labels.keys.map((f)=>CheckboxListTile(value:selected.contains(f),onChanged:(v)=>set(()=>v==true?selected.add(f):selected.remove(f)),title:Text(labels[f]??f),dense:true)).toList())),FilledButton.icon(onPressed:()=>Navigator.pop(ctx,selected),icon:const Icon(Icons.save_alt),label:const Text('SAVE TXT'))]))));});});
    if(chosen==null||chosen.isEmpty)return;
    final fields=labels.keys.where(chosen.contains).toList(); final b=StringBuffer();
    for(var i=0;i<filtered.length;i++){b.writeln('RECORD ${i+1}');for(final f in fields){b.writeln('${labels[f]??f}: ${filtered[i][f]??''}');}b.writeln();b.writeln(List.filled(70, '-').join());b.writeln();}
    final dir=await getTemporaryDirectory(); final file=File('${dir.path}/signal_student_results.txt');await file.writeAsString(b.toString());
    await Share.shareXFiles([XFile(file.path,mimeType:'text/plain')],text:'SIGNAL Student Search results');
  }

  void _openDetail(int i){setState(()=>selectedIndex=i);showModalBottomSheet(context:context,isScrollControlled:true,builder:(ctx)=>DraggableScrollableSheet(expand:false,initialChildSize:.86,maxChildSize:.96,builder:(_,scroll){final r=filtered[i];return SafeArea(child:Padding(padding:const EdgeInsets.fromLTRB(16,8,16,12),child:Column(children:[Row(children:[Expanded(child:Text('${r['name']??''}',style:const TextStyle(fontSize:20,fontWeight:FontWeight.w800))),IconButton(onPressed:()=>Navigator.pop(ctx),icon:const Icon(Icons.close))]),Text('${r['regno']??''}  •  ${r['branch']??''}',style:TextStyle(color:Theme.of(ctx).colorScheme.primary)),const Divider(),Expanded(child:ListView(controller:scroll,children:r.entries.where((e)=>e.key!='source_file'&&e.key!='source_files').map((e)=>Padding(padding:const EdgeInsets.symmetric(vertical:6),child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[SizedBox(width:150,child:Text(labels[e.key]??e.key,style:TextStyle(color:Theme.of(ctx).colorScheme.onSurfaceVariant,fontWeight:FontWeight.w600))),Expanded(child:Text('${e.value}'))]))).toList()))]));}));}

  @override Widget build(BuildContext context){final scheme=ColorScheme.fromSeed(seedColor:const Color(0xff28d7c4),brightness:dark?Brightness.dark:Brightness.light);return MaterialApp(debugShowCheckedModeBanner:false,theme:ThemeData(colorScheme:scheme,useMaterial3:true,brightness:dark?Brightness.dark:Brightness.light,scaffoldBackgroundColor:dark?const Color(0xff080c10):null,inputDecorationTheme:InputDecorationTheme(filled:true,fillColor:dark?const Color(0xff111820):null,border:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:BorderSide.none))),home:Scaffold(appBar:AppBar(title:Row(children:[ClipRRect(borderRadius:BorderRadius.circular(8),child:Image.asset('assets/signal_icon.png',width:34,height:34,fit:BoxFit.cover)),const SizedBox(width:10),const Text('SIGNAL',style:TextStyle(fontWeight:FontWeight.w800,letterSpacing:1.2))]),actions:[IconButton(tooltip:dark?'Light mode':'Dark mode',onPressed:()=>_theme(!dark),icon:Icon(dark?Icons.light_mode:Icons.dark_mode)),IconButton(tooltip:'Save results',onPressed:_export,icon:const Icon(Icons.save_alt))]),body:loading?const Center(child:CircularProgressIndicator()):_body()));}

  Widget _body(){return SafeArea(child:LayoutBuilder(builder:(ctx,c){return Column(children:[Padding(padding:const EdgeInsets.fromLTRB(14,12,14,8),child:Column(children:[TextField(controller:nameCtl,onChanged:(_)=>_runSearch(),decoration:InputDecoration(prefixIcon:const Icon(Icons.search),hintText:'Student name…',suffixIcon:PopupMenuButton<String>(onSelected:(v){setState(()=>nameMode=v);_runSearch();},itemBuilder:(_)=>const [PopupMenuItem(value:'Exact text',child:Text('Exact text')),PopupMenuItem(value:'Contains',child:Text('Contains'))],icon:const Icon(Icons.unfold_more)))),const SizedBox(height:8),TextField(controller:detailCtl,onChanged:(_)=>_runSearch(),decoration:InputDecoration(prefixIcon:const Icon(Icons.manage_search),hintText:'Other names / details…',suffixIcon:PopupMenuButton<String>(onSelected:(v){setState(()=>detailMode=v);_runSearch();},itemBuilder:(_)=>const [PopupMenuItem(value:'Exact text',child:Text('Exact text')),PopupMenuItem(value:'Contains',child:Text('Contains'))],icon:const Icon(Icons.unfold_more)))),const SizedBox(height:8),Row(children:[FilterChip(selected:similar,onSelected:(v){setState(()=>similar=v);_runSearch();},avatar:const Icon(Icons.auto_awesome,size:16),label:const Text('Similar spelling')),const SizedBox(width:8),OutlinedButton.icon(onPressed:()=>_filtersSheet(),icon:const Icon(Icons.tune),label:Text(filtersOpen?'Filters':'Filters')),const Spacer(),Text(status,style:TextStyle(color:Theme.of(ctx).colorScheme.onSurfaceVariant,fontSize:12))])])),
          Expanded(child:filtered.isEmpty?Center(child:Column(mainAxisSize:MainAxisSize.min,children:[Icon(Icons.search_off,size:54,color:Theme.of(ctx).colorScheme.onSurfaceVariant),const SizedBox(height:8),const Text('No matching students')]):ListView.separated(padding:const EdgeInsets.fromLTRB(14,6,14,20),itemCount:filtered.length,separatorBuilder:(_,__)=>const SizedBox(height:8),itemBuilder:(_,i){final r=filtered[i];final gender={'m':'Male','f':'Female'}[norm(r['gender'])]??'${r['gender']??''}';return Card(margin:EdgeInsets.zero,child:InkWell(borderRadius:BorderRadius.circular(14),onTap:()=>_openDetail(i),child:Padding(padding:const EdgeInsets.all(14),child:Row(children:[Container(width:44,height:44,decoration:BoxDecoration(color:Theme.of(ctx).colorScheme.primaryContainer,borderRadius:BorderRadius.circular(12)),child:Center(child:Text((('${r['name']??'?'}').trim().isEmpty?'?':'${r['name']??'?'}'.trim().substring(0,1)).toUpperCase(),style:TextStyle(fontWeight:FontWeight.w800,color:Theme.of(ctx).colorScheme.onPrimaryContainer))),),const SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${r['name']??''}',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w700,fontSize:15)),const SizedBox(height:3),Text('${r['regno']??''}  •  ${r['branch']??''}',maxLines:1,overflow:TextOverflow.ellipsis,style:TextStyle(color:Theme.of(ctx).colorScheme.onSurfaceVariant)),const SizedBox(height:2),Text('${r['town']??''}  •  ${r['district']??''}  •  $gender',maxLines:1,overflow:TextOverflow.ellipsis,style:TextStyle(fontSize:12,color:Theme.of(ctx).colorScheme.onSurfaceVariant))])),const Icon(Icons.chevron_right)]))));}))]);}));}
}

void main(){runApp(const SignalApp());}
