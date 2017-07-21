#!/usr/bin/env ruby
#
# Convert ClinVar XML file into RDF
#
# Copyright (C) 2017 Toshiaki Katayama <ktym@dbcls.jp>
#
# Pre-requirements:
#  % curl -O ftp://ftp.ncbi.nlm.nih.gov/pub/clinvar/xml/ClinVarFullRelease_2017-06.xml.gz
#  % gem install nokogiri
#  % gzip -dc ClinVarFullRelease_2017-06.xml | ruby clinvar2rdf.rb > ClinVarFullRelease_2017-06.rdf
#

# TODO:
# * decide which <tags> information in <ReferenceClinVarAssertion> to be moved under the variation:###
# * support <TraitSet>
# * support <MeasureRelationship>
# * may support SCV <ExteranalID>
# * decide how much support SCV's <MeasureSet> (less informative, might not normalized)
# * parse HGVS
# * use FALDO
# * link to Identifiers.org
# * update cvo ontology

require 'rubygems'
require 'nokogiri'
require 'active_support/all'

module TripleSupport
  @@turtle_indent = 1
  @@turtle_tabmax = 4

  def quote(str)
    return str.gsub('\\', '\\\\').gsub("\t", '\\t').gsub("\n", '\\n').gsub("\r", '\\r').gsub('"', '\\"').inspect
  end

  def quote_date(date)
    return %Q("#{date}"^^xsd:date)
  end

  def usdate2date(str)
    return Date.parse(str).strftime("%Y-%m-%d")  
  end

  def new_uuid
    require 'securerandom'
    return "<urn:uuid:#{SecureRandom.uuid}>"
  end

  def put_spo(subject, predicate, object)
    return [subject, predicate, object].join("\t") + " ."
  end

  def put_s(subject)
    puts
    puts subject
  end

  def put_po(predicate, object, continue = true)
    offset, margin = pad(predicate)
    if continue
      puts "#{offset}#{predicate}#{margin}#{object} ;"
    else
      puts "#{offset}#{predicate}#{margin}#{object} ."
    end
  end

  def put_blank(predicate, item, continue = true, &proc)
    offset, margin = pad(predicate)
    puts "#{offset}#{predicate}#{margin}["
    @@turtle_indent += 1
    proc.call(item)
    @@turtle_indent -= 1
    if continue
      puts "#{offset}] ;"
    else
      puts "#{offset}] ."
    end
  end

  def put_blank_po(predicate, object, continue = true)
    offset, margin = pad(predicate)
    put_po(predicate, object, continue)
  end

  def pad(str)
    offset = "\t" * @@turtle_indent
    margin = "\t" * tab(str)
    return [offset, margin]
  end

  def tab(str)
    tab_max = 4
    if (str.length + 1 > @@turtle_tabmax * 8)
      return 1
    else
      return @@turtle_tabmax - (str.length) / 8
    end
  end
end


module ClinVar

# @prefix dcat:               <http://www.w3.org/ns/dcat#> .
# @prefix clinvar_allele:     <http://purl.jp/bio/10/clinvar.allele/> .

PREFIXES = '# ClinVar ontology
@prefix cvo:                <http://purl.jp/bio/10/clinvar-ontology#> .
@prefix owl:                <http://www.w3.org/2002/07/owl#> .
@prefix rdf:                <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs:               <http://www.w3.org/2000/01/rdf-schema#> .
@prefix xsd:                <http://www.w3.org/2001/XMLSchema#> .
@prefix dc:                 <http://purl.org/dc/elements/1.1/> .
@prefix dct:                <http://purl.org/dc/terms/> .
@prefix foaf:               <http://xmlns.com/foaf/0.1/> .
@prefix faldo:              <http://biohackathon.org/resource/faldo#> .
@prefix obo:                <http://purl.obolibrary.org/obo/> .
@prefix sio:                <http://semanticscience.org/resource/> .
@prefix so:                 <http://purl.obolibrary.org/obo/so#> .
@prefix cvo:                <http://purl.jp/bio/10/clinvar/> .
@prefix exo:                <http://purl.jp/bio/10/exac/> .
@prefix clinvar:            <http://identifiers.org/clinvar/> .
@prefix clinvar_record:     <http://identifiers.org/clinvar.record/> .
@prefix clinvar_submission: <http://identifiers.org/clinvar.submission/> .
@prefix dbsnp:              <http://identifiers.org/dbsnp/> .
@prefix exac_variant:       <http://identifiers.org/exac.variant/> .
@prefix efo:                <http://identifiers.org/efo/> .
@prefix ensembl:            <http://identifiers.org/ensembl/> .
@prefix hgmd:               <http://identifiers.org/hgmd/> .
@prefix hgnc:               <http://identifiers.org/hgnc/> .
@prefix hp:                 <http://identifiers.org/hp/> .
@prefix medgen:             <http://identifiers.org/medgen/> .
@prefix mesh:               <http://identifiers.org/mesh/> .
@prefix ncbigene:           <http://identifiers.org/ncbigene/> .
@prefix omim:               <http://identifiers.org/omim/> .
@prefix orphanet:           <http://identifiers.org/orphanet/> .
@prefix pmc:                <http://identifiers.org/pmc/> .
@prefix pubmed:             <http://identifiers.org/pubmed/> .
@prefix snomedct:           <http://identifiers.org/snomedct/> .
@prefix uniprot:            <http://identifiers.org/uniprot/> .
@prefix refseq:             <http://identifiers.org/refseq/> .
@prefix ncbi_bookshelf:     <https://www.ncbi.nlm.nih.gov/books/> .
@prefix uniprot_protein:    <http://purl.uniprot.org/uniprot/> .
@prefix uniprot_annotation: <http://purl.uniprot.org/annotation/> .
@prefix clinvar_homepage:   <https://www.ncbi.nlm.nih.gov/clinvar/variation/> .
'

class Parser
  def initialize(xml)
    @ns = xml.namespaces
    puts PREFIXES
    parse_clinvarset(xml)
  end

  def parse_clinvarset(xml)
    xml.xpath('//ClinVarSet', @ns).each do |entry|
      next if entry.at('RecordStatus').content != "current"

      @entry = entry
      @clinvar = ClinVar::Variant.new

      parse_variant
      parse_rcv
      parse_scv
      output_rdf
    end
  end

  class UnsupportedXrefDB < StandardError; end

  def set_xref(key, value)
    value.xpath('Measure/XRef').each do |xref|
      case xref['DB']
      when "OMIM"
        key.xref_omim = xref['ID']
      when "dbSNP"
        key.xref_dbsnp = xref['Type'] + xref['ID']
      when "dbVar"
        # TODO
      else
        raise UnsupportedXrefDB, xref['DB']
      end
    end
  end

  def set_location(key, value)
    value.xpath('Measure/SequenceLocation').each do |seq|
      hash = {}
      # "Assembly"                  => "assembly"
      # "AssemblyAccessionVersion"  => "assembly_accession_version"
      # "AssemblyStatus"            => "assembly_status"
      # "Chr"                       => "chr"
      # "Accession"                 => "accession"
      # "start"                     => "start"
      # "stop"                      => "stop"
      # "display_start"             => "display_start"
      # "display_stop"              => "display_stop"
      # "variantLength"             => "variant_length"
      # "referenceAllele"           => "reference_allele"
      # "alternateAllele"           => "alternate_allele"
      seq.attribute_nodes.each do |x|
        hash[x.name.underscore] = x.value   # ActiveSupport::Inflector#underscore
      end
      key.locations << hash
    end
    if item = value.at('Measure/MeasureRelationship/SequenceLocation')
      key.location_strand = item['Strand']
    end
    if item = value.at('Measure/CytogeneticLocation')
      key.cytogenetic_location = item.content
    end
  end

  class UnsupportedAttributeTypeError < StandardError; end

  def set_attributes(key, value)
    path = './/AttributeSet'
    value.xpath(path, @ns).each do |item|
=begin
      type = item.at('Attribute[@Type]')['Type']
      case type
      when "AlleleFrequency"
        item.at('XRef')['DB']
        item.at('XRef')['ID']
      when "GlobalMinorAlleleFrequency"
        # TODO
      when "HGVS, coding, RefSeq"
        # TODO
      when "HGVS, genomic, RefSeqGene"
        # TODO
      when "HGVS, genomic, top level"
        # TODO
      when "HGVS, genomic, top level, previous"
        # TODO
      when "HGVS, protein, RefSeq"
        # TODO
      when "MolecularConsequence"
        # TODO
      when "ProteinChange1LetterCode"
        # TODO
      when "ProteinChange3LetterCode"
        # TODO
      when "HGVS, previous"
        # TODO
      when "HGVS, coding"
        # TODO
      when "HGVS, genomic, top level, other"
        # TODO
      when "HGVS, coding, LRG"
        # TODO
      when "HGVS, genomic, LRG"
        # TODO
      when "HGVS, non-coding"
        # TODO
      when "HGVS, non-validated"
        # TODO
      when "AbsoluteCopyNumber"
        # TODO
      when "Haploinsufficiency"
        # TODO
      when "Triplosensitivity"
        # TODO
      when "Location"
        # TODO
      else
        raise UnsupportedAttributeTypeError, type
      end
=end
      hash = { "value" => item.at('Attribute').content }
      item.at('Attribute').attribute_nodes.each do |x|
        hash[x.name.underscore] = x.value
      end
      item.xpath('XRef').each do |x|
        xref = [ x['DB'], x['ID'] ]
        hash["xref"] ||= []
        hash["xref"] << xref
      end
      key.attributes << hash
    end
  end

  def parse_variant
    path = './/ReferenceClinVarAssertion/MeasureSet'
    @clinvar.variant_id = @entry.at(path)['ID']
    @entry.xpath(path, @ns).each do |variant|
      @clinvar.variant_name = variant.at('Name/ElementValue[@Type="Preferred"]').content # TODO: other than Preferred?
      set_xref(@clinvar, variant)
      set_location(@clinvar, variant)
      set_attributes(@clinvar, variant)
    end
  end

  def set_assertion(key, value)
    key.assertion_type = value.at('Assertion')['Type']

    key.acc = value.at('ClinVarAccession')['Acc']
    key.version = value.at('ClinVarAccession')['Version']
    key.date_updated = value.at('ClinVarAccession')['DateUpdated']
    key.record_status = value.at('RecordStatus').content

    key.description = value.at('ClinicalSignificance/Description').content
    key.review_status = value.at('ClinicalSignificance/ReviewStatus').content
    key.date_last_evaluated = value.at('ClinicalSignificance')['DateLastEvaluated']

    key.sample_origin = value.at('ObservedIn/Sample/Origin').content
    key.sample_species = value.at('ObservedIn/Sample/Species').content
    key.sample_taxonomy_id = value.at('ObservedIn/Sample/Species')['TaxonomyId']
    key.sample_affected_status = value.at('ObservedIn/Sample/AffectedStatus').content
    key.collection_method = value.at('ObservedIn/Method/MethodType').content
  end

=begin
TODO: support other Attribute types
      <ObservedData ID="10770255">
        <Attribute integerValue="1" Type="VariantAlleles"/>
      </ObservedData>
      <ObservedData ID="10770255">
        <Attribute integerValue="0" Type="Homozygote"/>
      </ObservedData>
      <ObservedData ID="10770255">
        <Attribute integerValue="1" Type="SingleHeterozygote"/>
      </ObservedData>
      <ObservedData ID="10770255">
        <Attribute integerValue="0" Type="Homozygote"/>
      </ObservedData>
      <ObservedData ID="10770255">
        <Attribute integerValue="0" Type="SingleHeterozygote"/>
      </ObservedData>
=end
  def set_observations(key, value)
    path = './/ObservedIn/ObservedData'
    value.xpath(path, @ns).each do |item|
      key.observations << {
        :description => item.at('Attribute[@Type="Description"]').content,
        :citation => item.xpath('Citation/ID[@Source="PubMed"]', @ns).collect(&:text)
      } if item.at('Attribute[@Type="Description"]')
    end
  end

=begin
TODO: check the all possible cases

    <TraitSet Type="Disease" ID="7666">
      <Trait ID="14731" Type="Disease">
        <Name>
          <ElementValue Type="Preferred">Meckel syndrome type 1</ElementValue>
          <XRef ID="Meckel+syndrome+type1/4538" DB="Genetic Alliance"/>
          <XRef ID="3436" DB="Office of Rare Diseases"/>
        </Name>
        <Name>
          <ElementValue Type="Alternate">MECKEL-GRUBER SYNDROME, TYPE 1</ElementValue>
          <XRef Type="MIM" ID="249000" DB="OMIM"/>
        </Name>
        <Symbol>
          <ElementValue Type="Preferred">MKS1</ElementValue>
          <XRef Type="MIM" ID="249000" DB="OMIM"/>
          <XRef ID="3436" DB="Office of Rare Diseases"/>
        </Symbol>
        <AttributeSet>
          <Attribute Type="ModeOfInheritance" integerValue="263">Autosomal recessive inheritance</Attribute>
          <XRef ID="GTR000500622" DB="Genetic Testing Registry (GTR)"/>
          <XRef ID="GTR000511596" DB="Genetic Testing Registry (GTR)"/>
          <XRef ID="GTR000514978" DB="Genetic Testing Registry (GTR)"/>
          <XRef ID="GTR000521226" DB="Genetic Testing Registry (GTR)"/>
          <XRef ID="GTR000528276" DB="Genetic Testing Registry (GTR)"/>
          <XRef ID="GTR000528277" DB="Genetic Testing Registry (GTR)"/>
          <XRef ID="GTR000528542" DB="Genetic Testing Registry (GTR)"/>
          <XRef ID="GTR000528631" DB="Genetic Testing Registry (GTR)"/>
        </AttributeSet>
        <AttributeSet>
          <Attribute Type="age of onset">Antenatal</Attribute>
          <XRef ID="564" DB="Orphanet"/>
        </AttributeSet>
        <AttributeSet>
          <Attribute Type="prevalence">1-9 / 100 000</Attribute>
          <XRef ID="564" DB="Orphanet"/>
        </AttributeSet>
        <Citation Type="Translational/Evidence-based" Abbrev="EuroGenetest, 2011">
          <ID Source="PubMed">21368913</ID>
        </Citation>
        <XRef ID="C3714506" DB="MedGen"/>
        <XRef ID="564" DB="Orphanet"/>
        <XRef Type="MIM" ID="249000" DB="OMIM"/>
      </Trait>
    </TraitSet>
=end
  def set_traits(key, value)
    path = './/TraitSet'
    value.xpath(path, @ns).each do |item|
      hash = {}
      hash[:type] = item.at('Trait')['Type']
      if node = item.at('Trait/Name/ElementValue[@Type=Preferred]')
        hash[:name] = node.content
      end
      if node = item.at('Trait/Name/ElementValue[@Type=Alternate]')
        hash[:alternate] = node.content
      end
      hash[:xref] = item.xpath('.//XRef', @ns).map { |x| { :DB => x['DB'], :ID => x['ID'], :Type => x['Type'] } }
      key.traits << hash
    end
  end

  def parse_rcv
    path = './/ReferenceClinVarAssertion'
    @entry.xpath(path, @ns).each do |rcv|
      container = @clinvar.add_rcv
      container.title = @entry.at('Title').content
      container.date_created = @entry.at(path)['DateCreated']
      container.date_last_updated = @entry.at(path)['DateLastUpdated']
      set_assertion(container, rcv)
      set_observations(container, rcv)
      set_traits(container, rcv)
    end
  end

  def set_submission_id(key,value)
    key.title = value.at('ClinVarSubmissionID')['title']
    key.submitter = value.at('ClinVarSubmissionID')['submitter']
    key.submitter_date = value.at('ClinVarSubmissionID')['submitterDate']
  end

  def parse_scv
    path = './/ClinVarAssertion'
    @entry.xpath(path, @ns).each do |scv|
      container = @clinvar.rcv.add_scv
      set_submission_id(container, scv)
      set_assertion(container, scv)
      set_observations(container, scv)
      set_attributes(container, scv)
    end
  end

  def output_rdf
    @clinvar.to_rdf
  end
end

class Variant
  include TripleSupport

  attr_accessor :variant_id, :variant_name, :xref_omim, :xref_dbsnp, :locations, :location_strand, :cytogenetic_location, :attributes, :rcv

  def initialize
    @locations = []
    @attributes = []
  end

  def add_rcv
    @rcv = RCV.new
  end

  def to_rdf
    put_s("clinvar:#{@variant_id}")
    put_po("rdf:type", "cvo:Variant")
    put_po("dct:identifier", quote(@variant_id))
    put_po("rdfs:label", quote(@variant_name))
    put_po("foaf:homepage", "clinvar_homepage:#{@variant_id}")
    put_po("rdfs:seeAlso", "omim:#{@xref_omim}") if @xref_omim
    put_po("rdfs:seeAlso", "dbsnp:#{@xref_dbsnp}") if @xref_dbsnp
    @locations.each do |location|
      put_blank("cvo:sequence_location", location) { |item|
        item.each do |key, value|
          case key
          when "display_start", "display_stop"
            next
          when "start", "stop"       # cvo:start/stop seems too generic term
            key = "variant_#{key}"
            put_blank_po("cvo:#{key}", value)
          when "variant_length"
            put_blank_po("cvo:#{key}", value)
          when "accession"
            key = "sequence_#{key}"  # to avoid confusion with RCV/SCV accessions
            put_blank_po("cvo:#{key}", quote(value))
          else
            put_blank_po("cvo:#{key}", quote(value))
          end
        end
        put_blank_po("cvo:strand", quote(@location_strand || ""), false)
      }
    end
    put_po("cvo:cytogenetic_location", quote(@cytogenetic_location)) if @cytogenetic_location
    @attributes.each do |attribute|
      put_blank("cvo:attribute", attribute) { |item|
        item.each do |key, value|
          case key
          when "type"
            put_blank_po("cvo:attribute_type", quote(value))      # TODO introduce Classes?
          when "xref"
            value.each do |db, id|
              put_blank_po("cvo:attribute_xref_db", quote(db))
              put_blank_po("cvo:attribute_xref_id", quote(id))
              put_blank_po("rdfs:seeAlso", quote("#{db}:#{id}"))  # TODO need to make URIs
            end
          else
            put_blank_po("cvo:attribute_#{key}", quote(value))    # TODO need to parse HGVS
          end
        end
      }
    end
    phenotype_xrefs = []
    @rcv.traits.each do |trait|
      put_blank("cvo:phenotype", trait) { |item|
        put_blank_po("cvo:trait_type", quote(item[:type]))
        put_blank_po("cvo:trait_name", quote(item[:name])) if item[:name]
        put_blank_po("cvo:trait_alt_name", quote(item[:alternate])) if item[:alternate]
        item[:xref].each do |xref|
          put_blank("cvo:trait_xref", xref) { |hash|
            # TODO: check if there are other databases
            case hash[:DB]
            when "OMIM"
              db_prefix = "http://identifiers.org/omim"
              id_uri = "<#{db_prefix}/#{hash[:ID]}>"
              id_type = "<#{db_prefix}>"
              phenotype_xrefs << [ id_uri, id_type, hash[:ID] ]
            when "MedGen"
              db_prefix = "http://identifiers.org/medgen"
              id_uri = "<#{db_prefix}/#{hash[:ID]}>"
              id_type = "<#{db_prefix}>"
              phenotype_xrefs << [ id_uri, id_type, hash[:ID] ]
            end
            put_blank_po("cvo:trait_xref_db", quote(hash[:DB])) if hash[:DB]
            put_blank_po("cvo:trait_xref_id", quote(hash[:ID])) if hash[:ID]
            put_blank_po("cvo:trait_xref_type", quote(hash[:Type])) if hash[:Type]
          }
        end
      }
    end
    phenotype_xrefs.each do |uri, db, id|
      put_po("cvo:phenotype_xref", uri)
    end
    put_po("cvo:number_of_submissions", @rcv.scvs.size)
    put_po("cvo:reference", "clinvar_record:#{@rcv.acc}", false)
    phenotype_xrefs.each do |uri, db, id|
      put_s(uri)
      put_po("rdf:type", db)
      put_po("dc:identifier", quote(id), false)
    end

    @rcv.to_rdf
  end
end

class RCV
  include TripleSupport

  attr_accessor :acc, :version, :date_created, :date_last_updated, :date_updated, :title, :assertion_type, :description, :record_status, :review_status, :date_last_evaluated, :sample_origin, :sample_species, :sample_taxonomy_id, :sample_affected_status, :collection_method, :observations, :traits, :scvs

  def initialize
    @observations = []
    @traits = []
  end

  def add_scv
    @scvs ||= []
    @scvs << SCV.new
    return @scvs.last
  end

  def to_rdf(subject = 'clinvar_record', type = 'ReferenceClinVar')
    put_s("#{subject}:#{@acc}")
    put_po("rdf:type", "cvo:#{type}")
    put_po("dct:identifier", quote("#{@acc}.#{@version}"))
    put_po("cvo:accession", quote(@acc))
    put_po("cvo:version", quote(@version))
    put_po("rdfs:label", quote(@title)) if @title
    put_po("cvo:assertion_type", quote(@assertion_type)) if @assertion_type
    put_po("cvo:date_created", quote_date(@date_created)) if @date_created
    put_po("cvo:date_last_updated", quote_date(@date_last_updated)) if @date_last_updated
    put_po("cvo:date_updated", quote_date(@date_updated))
    put_po("cvo:record_status", quote(@record_status))
    put_po("cvo:clinical_significance", quote(@description))
    put_po("cvo:review_status", quote(@review_status))
    put_po("cvo:date_last_evaluated", quote_date(@date_last_evaluated))
    put_po("cvo:sample_origin", quote(@sample_origin))
    put_po("cvo:sample_species", quote(@sample_species))
    put_po("cvo:sample_taxonomy_id", quote(@sample_taxonomy_id)) if @sample_taxonomy_id
    put_po("cvo:sample_affected_status", quote(@sample_affected_status))
    put_po("cvo:collection_method", quote(@collection_method))
    @observations.each do |observation|
      put_blank("cvo:observation", observation) { |item|
        put_blank_po("rdfs:comment", quote(item[:description]))
        put_blank_po("dct:references", item[:citation].map{|pmid| "pubmed:#{pmid}"}.join(", "), false)
      }
    end

    if self.class == RCV
      scvs = @scvs.map{ |scv| "clinvar_submission:#{scv.acc}" }.join(", ")
      put_po("cvo:submission", scvs, false)

      @scvs.each do |scv|
        scv.to_rdf
      end
    end
  end
end

class SCV < RCV
  attr_accessor :submitter, :submitter_date, :attributes

  def initialize
    @observations = []
    @attributes = []
  end

  def to_rdf(subject = 'clinvar_submission', type = 'Submission')
    super
    @attributes.each do |attribute|
      put_blank("cvo:attribute", attribute) { |item|
        item.each do |key, value|
          case key
          when "type"
            put_blank_po("cvo:attribute_type", quote(value))      # TODO introduce Classes?
          when "xref"
            value.each do |db, id|
              put_blank_po("cvo:attribute_xref_db", quote(db))
              put_blank_po("cvo:attribute_xref_id", quote(id))
              put_blank_po("rdfs:seeAlso", quote("#{db}:#{id}"))  # TODO need to make URIs
            end
          else
            put_blank_po("cvo:attribute_#{key}", quote(value))    # TODO need to parse HGVS
          end
        end
      }
    end
    put_po("cvo:submitter", quote(@submitter))
    put_po("cvo:submission_date", quote_date(@submitter_date), false)
  end
end

end # module


ClinVar::Parser.new(Nokogiri::XML(ARGF))

