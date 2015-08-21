require 'spec_helper'

describe Arachni::Element::Form::DOM do
    it_should_behave_like 'element_dom', inputs: { 'param' => '1' }

    def auditable_extract_parameters( page )
        YAML.load( page.document.css( 'body' ).text )
    end

    before :each do
        @framework = Arachni::Framework.new
        @page      = Arachni::Page.from_url( "#{url}/form" )
        @auditor   = Auditor.new( @page, @framework )

        @form = @page.forms.first.dom
        @form.auditor = auditor
    end

    after :each do
        @framework.clean_up
        @framework.reset
    end

    subject { @form }
    let(:parent) { @form.parent }
    let(:url) { web_server_url_for( :form_dom ) }
    let(:auditor) { @auditor }
    let(:inputtable) do
        f = Arachni::Page.from_url( "#{url}/form/inputtable" ).forms.first.dom
        f.auditor = auditor
        f
    end

    describe '#type' do
        it 'returns :form_dom' do
            expect(subject.type).to eq(:form_dom)
        end
    end

    describe '.type' do
        it 'returns :form_dom' do
            expect(described_class.type).to eq(:form_dom)
        end
    end

    describe '#parent' do
        it 'returns the parent element' do
            expect(subject.parent).to be_kind_of Arachni::Element::Form
        end
    end

    describe '#inputs' do
        it 'uses the parent\'s inputs' do
            expect(subject.inputs).to eq(parent.inputs)
        end
    end

    describe '#locate' do
        it 'locates the live element' do
            called = false
            subject.with_browser do |browser|
                subject.browser = browser
                browser.load subject.page

                element = subject.locate
                expect(element).to be_kind_of Watir::HTMLElement

                expect(parent.class.from_document(
                    parent.url, Nokogiri::HTML(element.html)
                ).first).to eq(parent)

                called = true
            end

            subject.auditor.browser_cluster.wait
            expect(called).to be_truthy
        end
    end

    describe '#trigger' do
        it 'triggers the event required to submit the element' do
            inputs = { 'param'  => 'The.Dude' }
            subject.update inputs

            called = false
            subject.with_browser do |browser|
                subject.browser = browser
                browser.load subject.page

                subject.trigger

                page = browser.to_page

                expect(subject.inputs).to eq(auditable_extract_parameters( page ))
                called = true
            end

            subject.auditor.browser_cluster.wait
            expect(called).to be_truthy
        end

        it 'returns a playable transition' do
            inputs = { 'param'  => 'The.Dude' }
            subject.update inputs

            transitions = []
            called = false
            subject.with_browser do |browser|
                subject.browser = browser
                browser.load subject.page

                transitions = subject.trigger

                page = browser.to_page

                expect(subject.inputs).to eq(auditable_extract_parameters( page ))
                called = true
            end

            subject.auditor.browser_cluster.wait
            expect(called).to be_truthy

            called = false
            auditor.with_browser do |browser|
                browser.load subject.page
                expect(auditable_extract_parameters( browser.to_page )).to be_falsey

                transitions.each do |transition|
                    transition.play browser
                end

                expect(auditable_extract_parameters( browser.to_page )).to eq(inputs)
                called = true
            end
            auditor.browser_cluster.wait
            expect(called).to be_truthy
        end
    end

end
